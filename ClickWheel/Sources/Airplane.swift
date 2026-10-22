import Foundation

/// Toggles airplane mode through the private RadiosPreferences class (AppSupport), as Settings does.
/// Needs SCPreferences write access to com.apple.radios.plist.
final class AirplaneController: ObservableObject {
    @Published private(set) var enabled = false
    private let preferences: NSObject?

    init() {
        dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_NOW)
        preferences = (NSClassFromString("RadiosPreferences") as? NSObject.Type)?.init()
        refresh()
    }

    var available: Bool { preferences != nil }

    func setEnabled(_ on: Bool) {
        guard let preferences = preferences else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        let sel = NSSelectorFromString("setAirplaneMode:")
        unsafeBitCast(preferences.method(for: sel), to: Fn.self)(preferences, sel, on)
        preferences.perform(NSSelectorFromString("synchronize"))
        refresh()
    }

    func refresh() {
        enabled = (preferences?.value(forKey: "airplaneMode") as? Bool) ?? false
    }
}
