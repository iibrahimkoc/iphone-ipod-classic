import AppKit
import Combine

/// The other way round from the menu bar remote: the iPod's Mac Kumandası controls the Mac.
/// While it is open (Phone.remoteOpen), one ssh connection waits on the phone for its command
/// files and prints each one as it arrives; the Mac's volume and what Music or Spotify plays go
/// back in ".macstatus.json".
final class MacRemoteLink {
    private let phone: Phone
    private var process: Process?
    private var buffer = ""
    private var statusTimer: Timer?
    private var lastStatus = Data()
    private var lastWrite = Date.distantPast
    private var cancellable: AnyCancellable?

    init(phone: Phone) {
        self.phone = phone
        cancellable = phone.$remoteOpen.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] open in
            open ? self?.start() : self?.stop()
        }
    }

    private func start() {
        guard process == nil else { return }
        // Ends by itself once the iPod leaves the screen and removes the flag.
        let loop = "cd \(quote(phone.musicFolder)) && while [ -e .macremote ]; do "
            + "for f in $(find . -maxdepth 1 -name '.mac-*' | sort); do cat \"$f\"; echo; rm -f \"$f\"; done; sleep 0.15; done"
        guard let process = phone.sshProcess(loop) else { return }
        let output = Pipe()
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.received(text) }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                output.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                // The connection dropped while the screen is still open: connect again.
                if self.phone.remoteOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.phone.remoteOpen { self.start() } }
                }
            }
        }
        guard (try? process.run()) != nil else { return }
        self.process = process
        writeStatus(force: true)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.writeStatus(force: false) }
    }

    private func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        process?.terminate()
        process = nil
    }

    private func received(_ text: String) {
        buffer += text
        while let end = buffer.firstIndex(of: "\n") {
            let line = buffer[..<end].trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...end)
            if !line.isEmpty { run(line) }
        }
    }

    private func run(_ command: String) {
        let parts = command.split(separator: " ")
        switch parts.first {
        case "toggle"?: MediaKeys.press(MediaKeys.play)
        case "next"?: MediaKeys.press(MediaKeys.next)
        case "prev"?: MediaKeys.press(MediaKeys.previous)
        case "vol"?:
            if parts.count > 1, let percent = Float(parts[1]) { MacAudio.setVolume(percent / 100) }
        default: return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.writeStatus(force: true) }
    }

    /// Sent when something changed, and every 2 s anyway so the iPod knows the Mac is listening.
    private func writeStatus(force: Bool) {
        let track = NowPlayingApps.current()
        let status: [String: Any] = [
            "volume": Int((MacAudio.volume * 100).rounded()),
            "muted": MacAudio.muted,
            "title": track?.title ?? "",
            "artist": track?.artist ?? "",
            "app": track?.app ?? "",
            // Music and Spotify say whether they play; for anything else, whether the Mac makes sound.
            "playing": track?.playing ?? AppDelegate.macAudio.playing,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys) else { return }
        guard force || data != lastStatus || Date().timeIntervalSince(lastWrite) >= 2 else { return }
        lastStatus = data
        lastWrite = Date()
        var stamped = status
        stamped["time"] = Date().timeIntervalSince1970
        if let out = try? JSONSerialization.data(withJSONObject: stamped, options: .sortedKeys) {
            phone.put(out, as: ".macstatus.json")
        }
    }

    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Presses the Mac's media keys, so whatever plays on it (a browser, Music, Spotify) reacts.
/// Marked, so the app's own key tap lets them through instead of sending them to the iPod.
enum MediaKeys {
    static let play: Int32 = 16      // NX_KEYTYPE_PLAY
    static let next: Int32 = 17      // NX_KEYTYPE_NEXT
    static let previous: Int32 = 18  // NX_KEYTYPE_PREVIOUS
    static let marker: Int64 = 0x1D0D

    static func press(_ key: Int32) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: Int(key) << 16 | state << 8, data2: -1)
            guard let cgEvent = event?.cgEvent else { continue }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: marker)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}

/// What Music or Spotify is playing, asked over AppleScript (macOS no longer tells other apps
/// what plays where). Apps that aren't running are left alone, so nothing gets launched.
enum NowPlayingApps {
    struct Track {
        let title, artist, app: String
        let playing: Bool
    }

    private static let apps = [("com.spotify.client", "Spotify", "Spotify"), ("com.apple.Music", "Music", "Müzik")]

    static func current() -> Track? {
        var paused: Track?
        for (bundle, name, label) in apps where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            let source = """
            tell application "\(name)"
                if player state is stopped then return ""
                return (player state as text) & linefeed & (name of current track) & linefeed & (artist of current track)
            end tell
            """
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(nil).stringValue else { continue }
            let lines = result.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }
            let track = Track(title: lines[1], artist: lines[2], app: label, playing: lines[0] == "playing")
            if lines[0] == "playing" { return track }
            paused = paused ?? track
        }
        return paused
    }
}
