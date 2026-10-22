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

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
        update()
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
