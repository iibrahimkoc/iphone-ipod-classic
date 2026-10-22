import AppKit
import os

/// "Mac ses tuşları iPod'da": while the iPod is playing, the Mac's volume up/down and mute keys
/// change the iPod's volume instead of the Mac's; when it is paused they are the Mac's again.
/// Play/pause, next and previous are left to macOS, which sends them to the app in Now Playing
/// (see MacNowPlaying), so they work for the Mac's own players too. Catching the keys takes an event tap, so the app has to be
/// allowed under Privacy & Security → Accessibility (again after every rebuild: the ad-hoc
/// signature changes).
enum VolumeKeys {
    private static var tap: CFMachPort?
    private static let log = Logger(subsystem: "com.ibrahimkoc.ipodmuzik", category: "keys")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "volumeKeys") }
        set {
            UserDefaults.standard.set(newValue, forKey: "volumeKeys")
            update(ask: true)
        }
    }

    /// False while the switch is on but Accessibility hasn't been granted yet.
    static var running: Bool { tap != nil }

    /// Starts or stops the tap. `ask` shows the system's Accessibility prompt when needed; until it
    /// is granted the tap is retried every 2 s.
    static func update(ask: Bool = false) {
        if !enabled {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                self.tap = nil
            }
            return
        }
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): ask] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            log.notice("no Accessibility permission yet")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { update() }
            return
        }
        // NX_SYSDEFINED (14): media and volume keys.
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1) << 14,
                                callback: { _, type, event, _ in VolumeKeys.handle(type, event) }, userInfo: nil)
        guard let tap = tap else {
            log.error("event tap could not be created")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { update() }
            return
        }
        log.notice("event tap running")
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// Swallows the volume keys and turns them into iPod commands; everything else passes through.
    private static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let phone = AppDelegate.phone
        guard let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        guard phone.found, phone.nowPlaying?.playing == true else {
            log.notice("key passed on: iPod not playing")
            return Unmanaged.passUnretained(event)
        }
        let code = (key.data1 & 0xFFFF0000) >> 16
        let pressed = (key.data1 & 0xFF00) >> 8 == 0x0A
        let repeated = key.data1 & 1 != 0
        log.notice("key \(code) pressed \(pressed) repeat \(repeated)")
        switch code {
        case 0: if pressed { phone.stepVolume(1) }   // NX_KEYTYPE_SOUND_UP
        case 1: if pressed { phone.stepVolume(-1) }  // NX_KEYTYPE_SOUND_DOWN
        case 7: if pressed && !repeated { phone.toggleMute() }  // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        return nil
    }
}
