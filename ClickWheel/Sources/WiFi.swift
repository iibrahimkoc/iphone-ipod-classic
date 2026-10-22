import Foundation

/// Drives the private MobileWiFi framework (the C API Settings uses) so networks can be
/// joined from inside the app. Needs the com.apple.wifi.manager-access entitlement.
final class WiFiController: ObservableObject {
    struct Network {
        /// A WiFiNetworkRef, kept alive by `scanResults`.
        let ref: UnsafeRawPointer
        let ssid: String
        let rssi: Int
        let secure: Bool
        let known: Bool
    }

    @Published private(set) var powered = false
    @Published private(set) var current: String?
    @Published private(set) var networks: [Network] = []
    @Published private(set) var joining: String?
    @Published private(set) var failed: String?
    @Published private(set) var ipAddress: String?

    private typealias ScanCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void
    private typealias AssociateCallback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void

    private let lib = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW)
    private var manager: UnsafeMutableRawPointer?
    private var device: UnsafeRawPointer?
    private var devices: CFArray?
    private var scanResults: CFArray?
    private var timer: Timer?

    init() {
        guard let create = sym("WiFiManagerClientCreate", (@convention(c) (CFAllocator?, Int32) -> UnsafeMutableRawPointer?).self),
              let manager = create(kCFAllocatorDefault, 0) else { return }
        self.manager = manager
        sym("WiFiManagerClientScheduleWithRunLoop", (@convention(c) (UnsafeMutableRawPointer, CFRunLoop, CFString) -> Void).self)?(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if let copyDevices = sym("WiFiManagerClientCopyDevices", (@convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?).self),
           let raw = copyDevices(manager) {
            let devices = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
            // Kept so the device ref stays alive.
            self.devices = devices
            if CFArrayGetCount(devices) > 0 {
                device = CFArrayGetValueAtIndex(devices, 0)
            }
        }
        refresh()
    }

    var available: Bool { manager != nil && device != nil }

    /// Scans now and every 10 s, and refreshes status every 2 s, while the Wi-Fi screen is open.
    func startScanning() {
        refresh()
        scan()
        var ticks = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            ticks += 1
            self?.refresh()
            if ticks % 5 == 0 { self?.scan() }
        }
    }

    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }

    func setPowered(_ on: Bool) {
        guard let manager = manager else { return }
        sym("WiFiManagerClientSetPower", (@convention(c) (UnsafeMutableRawPointer, Bool) -> Void).self)?(manager, on)
        if !on { networks = [] }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refresh()
            if on { self?.scan() }
        }
    }

    /// Joins a saved or open network directly, or a new secured one with `password`.
    func join(_ network: Network, password: String? = nil) {
        guard let device = device,
              let associate = sym("WiFiDeviceClientAssociateAsync",
                                  (@convention(c) (UnsafeRawPointer, UnsafeRawPointer, AssociateCallback, UnsafeMutableRawPointer?) -> Int32).self)
        else { return }
        var target = network.ref
        if let password = password,
           let copy = sym("WiFiNetworkCreateCopy", (@convention(c) (CFAllocator?, UnsafeRawPointer) -> UnsafeRawPointer?).self)?(kCFAllocatorDefault, network.ref) {
            sym("WiFiNetworkSetPassword", (@convention(c) (UnsafeRawPointer, CFString) -> Void).self)?(copy, password as CFString)
            target = copy
        }
        joining = network.ssid
        failed = nil
        let callback: AssociateCallback = { _, _, _, error, context in
            guard let context = context else { return }
            let controller = Unmanaged<WiFiController>.fromOpaque(context).takeUnretainedValue()
            controller.failed = error == 0 ? nil : controller.joining
            controller.joining = nil
            controller.refresh()
        }
        if associate(device, target, callback, Unmanaged.passUnretained(self).toOpaque()) != 0 {
            joining = nil
            failed = network.ssid
        }
    }

    func forgetCurrent() {
        guard let manager = manager, let device = device,
              let raw = sym("WiFiDeviceClientCopyCurrentNetwork", (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)?(device)
        else { return }
        sym("WiFiManagerClientRemoveNetwork", (@convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void).self)?(manager, raw)
        sym("WiFiDeviceClientDisassociate", (@convention(c) (UnsafeRawPointer) -> Void).self)?(device)
        Unmanaged<AnyObject>.fromOpaque(raw).release()
        refresh()
    }

    private func scan() {
        guard powered, let device = device,
              let scanAsync = sym("WiFiDeviceClientScanAsync",
                                  (@convention(c) (UnsafeRawPointer, CFDictionary, ScanCallback, UnsafeMutableRawPointer?) -> Int32).self)
        else { return }
        let callback: ScanCallback = { _, results, _, context in
            guard let context = context, let results = results else { return }
            let controller = Unmanaged<WiFiController>.fromOpaque(context).takeUnretainedValue()
            controller.scanResults = Unmanaged<CFArray>.fromOpaque(results).takeUnretainedValue()
            controller.rebuildNetworks()
        }
        _ = scanAsync(device, [:] as CFDictionary, callback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func refresh() {
        guard let manager = manager, let device = device else { return }
        powered = sym("WiFiManagerClientGetPower", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self)?(manager) ?? false
        if let raw = sym("WiFiDeviceClientCopyCurrentNetwork", (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)?(device) {
            current = ssid(of: raw)
            Unmanaged<AnyObject>.fromOpaque(raw).release()
        } else {
            current = nil
        }
        ipAddress = Self.wifiAddress()
        if !powered { networks = [] }
    }

    private func rebuildNetworks() {
        guard let results = scanResults else { return }
        let known = knownSSIDs()
        var strongest: [String: Network] = [:]
        for index in 0 ..< CFArrayGetCount(results) {
            guard let ref = CFArrayGetValueAtIndex(results, index) else { continue }
            let name = ssid(of: ref)
            // Hidden networks (including iPhone hotspots whose settings page isn't open) have no name.
            guard !name.isEmpty else { continue }
            let network = Network(ref: ref, ssid: name,
                                  rssi: (property(ref, "RSSI") as? Int) ?? -100,
                                  secure: property(ref, "WPA_IE") != nil || property(ref, "RSN_IE") != nil
                                      || (sym("WiFiNetworkIsWEP", (@convention(c) (UnsafeRawPointer) -> Bool).self)?(ref) ?? false),
                                  known: known.contains(name))
            if network.rssi > strongest[name]?.rssi ?? Int.min {
                strongest[name] = network
            }
        }
        networks = strongest.values.sorted { $0.rssi > $1.rssi }
    }

    private func knownSSIDs() -> Set<String> {
        guard let manager = manager,
              let raw = sym("WiFiManagerClientCopyNetworks", (@convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?).self)?(manager)
        else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        return Set((0 ..< CFArrayGetCount(array)).compactMap { CFArrayGetValueAtIndex(array, $0).map(ssid(of:)) })
    }

    private func ssid(of network: UnsafeRawPointer) -> String {
        guard let raw = sym("WiFiNetworkGetSSID", (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)?(network) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private func property(_ network: UnsafeRawPointer, _ key: String) -> Any? {
        guard let raw = sym("WiFiNetworkGetProperty", (@convention(c) (UnsafeRawPointer, CFString) -> UnsafeRawPointer?).self)?(network, key as CFString)
        else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let lib = lib, let pointer = dlsym(lib, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard String(cString: interface.ifa_name) == "en0",
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}
