import UIKit
import notify

/// Where the battery goes, for Pil › Kullanım: each stretch between two changes (the screen on the
/// iPod, the display turning off or on, the music starting or stopping, the battery level) is
/// charged to what the phone was doing, as time and battery used. Time on the charger isn't counted.
/// Kept across launches until "Sıfırla"; it only does work when something changes.
final class BatteryUsage {
    enum Activity: String, CaseIterable {
        case menus, music, games, camera, macRemote, screenOffMusic, screenOff

        var name: String {
            switch self {
            case .menus: return "Menüler"
            case .music: return "Şimdi Çalıyor"
            case .games: return "Oyunlar"
            case .camera: return "Kamera ve Fotoğraflar"
            case .macRemote: return "Mac Kumandası"
            case .screenOffMusic: return "Ekran Kapalı, Müzik"
            case .screenOff: return "Ekran Kapalı"
            }
        }
    }

    struct Total {
        var seconds: TimeInterval = 0
        /// Battery used, as a fraction of a full charge.
        var used: Double = 0
    }

    private(set) var totals: [Activity: Total] = [:]
    private(set) var since = Date()
    private(set) var screenOff = false

    /// What the screen shows while it is on, and whether music is playing.
    private let onScreen: () -> Activity
    private let playing: () -> Bool
    private var last: (date: Date, charge: Double?, activity: Activity, charging: Bool)?
    private var blankToken: Int32 = 0
    private var observers: [NSObjectProtocol] = []
    private static let key = "batteryUsage"

    init(onScreen: @escaping () -> Activity, playing: @escaping () -> Bool) {
        self.onScreen = onScreen
        self.playing = playing
        load()
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, .main) { [weak self] token in
            var blanked: UInt64 = 0
            notify_get_state(token, &blanked)
            self?.screenOff = blanked != 0
            self?.checkpoint()
        }
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkpoint()
            })
        }
        DispatchQueue.main.async { self.checkpoint() }
    }

    var activity: Activity {
        screenOff ? (playing() ? .screenOffMusic : .screenOff) : onScreen()
    }

    /// Charges the time and battery since the last checkpoint to what was going on then.
    func checkpoint() {
        let now = Date()
        let charge = BatteryGauge.charge()
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full
        if let last = last, !last.charging, !charging, let before = last.charge, let after = charge {
            totals[last.activity, default: Total()].seconds += now.timeIntervalSince(last.date)
            totals[last.activity, default: Total()].used += before - after
            save()
        }
        last = (now, charge, activity, charging)
    }

    func reset() {
        totals = [:]
        since = Date()
        last = nil
        save()
        checkpoint()
    }

    private func save() {
        var stored: [String: [Double]] = [:]
        for (activity, total) in totals { stored[activity.rawValue] = [total.seconds, total.used] }
        UserDefaults.standard.set(["since": since.timeIntervalSince1970, "totals": stored], forKey: Self.key)
    }

    private func load() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.key) else { return }
        if let since = stored["since"] as? Double { self.since = Date(timeIntervalSince1970: since) }
        for (name, values) in stored["totals"] as? [String: [Double]] ?? [:] {
            guard let activity = Activity(rawValue: name), values.count == 2 else { continue }
            totals[activity] = Total(seconds: values[0], used: values[1])
        }
    }
}

/// The battery's charge from its gauge (AppleSmartBattery in the IORegistry), in mAh, so a few
/// minutes of use show up instead of waiting for the 1 % level to move. IOKit has no Swift
/// headers on iOS, so its functions are looked up; the 1 % level is used if they can't be.
enum BatteryGauge {
    private typealias Matching = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias GetService = @convention(c) (mach_port_t, UnsafeMutableRawPointer?) -> mach_port_t
    private typealias CreateProperty = @convention(c) (mach_port_t, CFString, CFAllocator?, UInt32) -> UnsafeRawPointer?

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func function<T>(_ name: String) -> T? {
        guard let iokit = iokit, let symbol = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let createProperty: CreateProperty? = function("IORegistryEntryCreateCFProperty")

    /// Kept for the app's lifetime.
    private static let service: mach_port_t = {
        guard let matching: Matching = function("IOServiceMatching"),
              let getService: GetService = function("IOServiceGetMatchingService") else { return 0 }
        // IOServiceGetMatchingService takes over the matching dictionary.
        return getService(0, matching("AppleSmartBattery"))
    }()

    private static func integer(_ key: String) -> Int? {
        guard service != 0, let createProperty = createProperty,
              let value = createProperty(service, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(value).takeRetainedValue() as? Int
    }

    /// The charge as a fraction of a full battery.
    static func charge() -> Double? {
        if let current = integer("AppleRawCurrentCapacity"), let full = integer("AppleRawMaxCapacity"), full > 0 {
            return Double(current) / Double(full)
        }
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }
}
