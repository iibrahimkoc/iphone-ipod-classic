import Foundation

/// Drives the private BluetoothManager framework (the one Settings uses) so headphones can be
/// paired and connected from inside the app. Needs the com.apple.bluetooth.system entitlement.
final class BluetoothController: ObservableObject {
    struct Device {
        let object: NSObject
        let name: String
        let address: String
        let paired: Bool
        let connected: Bool
    }

    @Published private(set) var powered = false
    @Published private(set) var devices: [Device] = []
    @Published private(set) var connecting: String?

    private let manager: NSObject?
    private var discovered: [String: NSObject] = [:]
    private var observer: NSObjectProtocol?

    init() {
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW)
        let cls = NSClassFromString("BluetoothManager") as? NSObject.Type
        manager = cls?.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        observer = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: .main) { [weak self] note in
            guard note.name.rawValue.hasPrefix("Bluetooth") else { return }
            self?.handle(note)
        }
        refresh()
    }

    var available: Bool { manager != nil }

    func setPowered(_ on: Bool) {
        guard let manager = manager else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Bool
        let sel = NSSelectorFromString("setPowered:")
        _ = unsafeBitCast(manager.method(for: sel), to: Fn.self)(manager, sel, on)
        if on { startScanning() }
    }

    func startScanning() {
        guard let manager = manager, powered else { return }
        setBool("setDevicePairingEnabled:", true)
        setBool("setConnectable:", true)
        setBool("setDeviceScanningEnabled:", true)
        typealias Fn = @convention(c) (NSObject, Selector, UInt32) -> Void
        let sel = NSSelectorFromString("scanForServices:")
        unsafeBitCast(manager.method(for: sel), to: Fn.self)(manager, sel, 0xFFFF_FFFF)
    }

    func stopScanning() {
        setBool("setDeviceScanningEnabled:", false)
    }

    /// Connects (pairing first if needed) or disconnects the device.
    func toggle(_ device: Device) {
        if device.connected {
            device.object.perform(NSSelectorFromString("disconnect"))
        } else {
            connecting = device.address
            manager?.perform(NSSelectorFromString("connectDevice:"), with: device.object)
        }
    }

    func forget(_ device: Device) {
        manager?.perform(NSSelectorFromString("unpairDevice:"), with: device.object)
        discovered[device.address] = nil
        refresh()
    }

    private func handle(_ note: Notification) {
        let name = note.name.rawValue
        if name == "BluetoothDeviceDiscoveredNotification", let device = note.object as? NSObject {
            discovered[string(device, "address")] = device
        }
        // Headphones pair with "just works" SSP or a fixed PIN; there is no screen to confirm a code on.
        if name.contains("Pairing") {
            let device = (note.object as? NSDictionary)?["device"] as? NSObject ?? note.object as? NSObject
            if let device = device, device.responds(to: NSSelectorFromString("address")) {
                if name.contains("PIN") {
                    manager?.perform(NSSelectorFromString("setPincode:forDevice:"), with: "0000", with: device)
                } else {
                    typealias Fn = @convention(c) (NSObject, Selector, Int, NSObject) -> Void
                    let sel = NSSelectorFromString("acceptSSP:forDevice:")
                    if let manager = manager {
                        unsafeBitCast(manager.method(for: sel), to: Fn.self)(manager, sel, 0, device)
                    }
                }
            }
        }
        if name.contains("ConnectSuccess") || name.contains("ConnectFailed") || name.contains("Disconnect") {
            connecting = nil
        }
        if name == "BluetoothPowerChangedNotification" || name == "BluetoothAvailabilityChangedNotification" {
            let wasPowered = powered
            refresh()
            if powered && !wasPowered { startScanning() }
            return
        }
        refresh()
    }

    private func refresh() {
        guard let manager = manager else { return }
        powered = (manager.value(forKey: "powered") as? Bool) ?? false
        guard powered else {
            devices = []
            discovered = [:]
            return
        }
        let paired = manager.perform(NSSelectorFromString("pairedDevices"))?.takeUnretainedValue() as? [NSObject] ?? []
        var all = paired
        let pairedAddresses = Set(paired.map { string($0, "address") })
        all += discovered.filter { !pairedAddresses.contains($0.key) }.map(\.value)
        devices = all.map { object in
            Device(object: object,
                   name: string(object, "name"),
                   address: string(object, "address"),
                   paired: pairedAddresses.contains(string(object, "address")),
                   connected: (object.value(forKey: "connected") as? Bool) ?? false)
        }
        .filter { !$0.name.isEmpty }
        // Paired first, then the rest alphabetically, so the list doesn't jump around while scanning.
        .sorted { ($0.paired ? 0 : 1, $0.name) < ($1.paired ? 0 : 1, $1.name) }
        if let address = connecting, devices.first(where: { $0.address == address })?.connected == true {
            connecting = nil
        }
    }

    private func setBool(_ selector: String, _ value: Bool) {
        guard let manager = manager else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        let sel = NSSelectorFromString(selector)
        unsafeBitCast(manager.method(for: sel), to: Fn.self)(manager, sel, value)
    }

    private func string(_ object: NSObject, _ key: String) -> String {
        object.perform(NSSelectorFromString(key))?.takeUnretainedValue() as? String ?? ""
    }
}
