import UIKit

/// Watches the battery. At 20 % it shows an iPod-style warning and turns on Low Power Mode.
/// Below 10 % (not charging) it enters "quarantine": if the battery runs out the phone shuts down
/// and loses the jailbreak, so the app strips everything back to save power until it is charged.
/// Low Power Mode turns off again once charged past 80 %.
final class BatteryMonitor: ObservableObject {
    enum Warning {
        case low
    }

    /// "Pil Testi" states that override the real battery so the behavior can be previewed.
    static let simulations: [(name: String, level: Float, charging: Bool)] = [
        ("%20", 0.20, false), ("%9", 0.09, false), ("Şarjda", 0.09, true),
    ]

    @Published private(set) var level: Float = -1
    @Published private(set) var charging = false
    @Published private(set) var warning: Warning?
    @Published private(set) var simulation: Int?
    @Published private(set) var quarantine = false {
        didSet { if quarantine != oldValue { onQuarantineChange?(quarantine) } }
    }
    var onQuarantineChange: ((Bool) -> Void)?

    /// The lowest threshold already warned about, so each warning shows once per discharge.
    private var warnedThreshold = 100
    private var hideWarning: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var sampleTimer: Timer?

    /// Battery readings of the current charge or discharge, for the time estimate. Persisted so a
    /// relaunch doesn't start the estimate over.
    private var samples: [(date: Date, level: Float)] = BatteryMonitor.loadSamples()
    private static let samplesKey = "batterySamples"
    private static let estimateWindow: TimeInterval = 2 * 3600

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
                self?.recordSample()
            })
        }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.recordSample() }
        update()
        recordSample()
    }

    // MARK: Time estimate

    /// Seconds until empty (discharging) or full (charging), from the rate over the last two
    /// hours; nil until there are at least 15 minutes and a 2 % change to go on.
    var estimate: TimeInterval? {
        guard simulation == nil, level >= 0, let first = samples.first, let last = samples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let change = abs(last.level - first.level)
        guard span >= 15 * 60, change >= 0.02 else { return nil }
        let perSecond = Double(change) / span
        return Double(charging ? 1 - level : level) / perSecond
    }

    private func recordSample() {
        guard simulation == nil else { return }
        let device = UIDevice.current
        let level = device.batteryLevel
        guard level >= 0 else { return }
        let isCharging = device.batteryState == .charging || device.batteryState == .full
        // A new series starts whenever the phone is plugged in or unplugged.
        if let lastCharging = UserDefaults.standard.object(forKey: "batterySamplesCharging") as? Bool,
           lastCharging != isCharging {
            samples = []
        }
        UserDefaults.standard.set(isCharging, forKey: "batterySamplesCharging")
        let now = Date()
        samples.append((now, level))
        samples.removeAll { now.timeIntervalSince($0.date) > Self.estimateWindow }
        UserDefaults.standard.set(samples.map { [$0.date.timeIntervalSince1970, Double($0.level)] }, forKey: Self.samplesKey)
    }

    private static func loadSamples() -> [(date: Date, level: Float)] {
        let stored = UserDefaults.standard.array(forKey: samplesKey) as? [[Double]] ?? []
        return stored.compactMap { $0.count == 2 ? (Date(timeIntervalSince1970: $0[0]), Float($0[1])) : nil }
    }

    var isLow: Bool { level >= 0 && level <= 0.20 && !charging }

    func cycleSimulation() {
        switch simulation {
        case nil: simulation = 0
        case let index? where index + 1 < Self.simulations.count: simulation = index + 1
        default: simulation = nil
        }
        if simulation == 0 || simulation == nil { warnedThreshold = 100 }
        update()
    }

    func dismissWarning() {
        warning = nil
    }

    private func update() {
        if let index = simulation {
            level = Self.simulations[index].level
            charging = Self.simulations[index].charging
        } else {
            let device = UIDevice.current
            level = device.batteryLevel
            charging = device.batteryState == .charging || device.batteryState == .full
        }
        guard level >= 0 else { return }

        if charging {
            warning = nil
            warnedThreshold = 100
            quarantine = false
            if level >= 0.80 && simulation == nil { LowPowerMode.set(false) }
            return
        }

        if level < 0.10 {
            warning = nil
            quarantine = true
            if simulation == nil { LowPowerMode.set(true) }
        } else if level <= 0.20 && warnedThreshold > 20 {
            show(.low)
            if simulation == nil { LowPowerMode.set(true) }
            warnedThreshold = 20
        }
    }

    private func show(_ kind: Warning) {
        warning = kind
        hideWarning?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissWarning() }
        hideWarning = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// Low Power Mode through the private _CDBatterySaver class (CoreDuet), as Settings does.
enum LowPowerMode {
    static func set(_ on: Bool) {
        guard ProcessInfo.processInfo.isLowPowerModeEnabled != on else { return }
        dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet", RTLD_NOW)
        guard let cls = NSClassFromString("_CDBatterySaver") as? NSObject.Type,
              let saver = cls.perform(NSSelectorFromString("batterySaver"))?.takeUnretainedValue() as? NSObject
        else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int, UnsafeMutableRawPointer?) -> Bool
        let sel = NSSelectorFromString("setPowerMode:error:")
        guard saver.responds(to: sel) else { return }
        _ = unsafeBitCast(saver.method(for: sel), to: Fn.self)(saver, sel, on ? 1 : 0, nil)
    }
}
