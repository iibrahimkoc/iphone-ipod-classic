import AVFoundation

/// Lets the Mac's iPod Müzik app control playback over SSH. The Mac drops a ".command" file in
/// the music folder (watched, so it's handled at once), and the app keeps ".nowplaying.json"
/// there up to date for the Mac to read.
///
/// Commands: toggle, next, prev, vol <0-100>, and for testing from the Mac: shot (opens the camera
/// if needed and takes a photo), deleteshot (deletes that photo)
final class RemoteControl {
    private let player: PlayerController
    private let volume: VolumeController
    private let folder = SongLibrary.folder
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var lastStatus = Data()

    init(player: PlayerController, volume: VolumeController) {
        self.player = player
        self.volume = volume
        let descriptor = open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.readCommand() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.writeStatus() }
    }

    static let shot = Notification.Name("com.ibrahimkoc.clickwheel.shot")
    static let deleteShot = Notification.Name("com.ibrahimkoc.clickwheel.deleteshot")

    private func readCommand() {
        let file = folder.appendingPathComponent(".command")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        switch parts.first {
        case "toggle"?: player.togglePlay()
        case "next"?: player.next()
        case "prev"?: player.previous()
        case "shot"?:
            NotificationCenter.default.post(name: Self.shot, object: nil)
        case "deleteshot"?:
            NotificationCenter.default.post(name: Self.deleteShot, object: nil)
        case "vol"?:
            if parts.count > 1, let percent = Float(parts[1]) { volume.set(percent / 100) }
        default: break
        }
        writeStatus()
    }

    /// Rewritten only when something changed.
    private func writeStatus() {
        let song = player.item
        let status: [String: Any] = [
            "title": song?.title ?? "",
            "artist": song.map { $0.artistName } ?? "",
            "playing": player.isPlaying,
            "elapsed": Int(player.elapsed),
            "duration": Int(player.duration),
            // The volume view's slider follows the system volume, side buttons included.
            "volume": Int((volume.currentLevel * 100).rounded()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys), data != lastStatus else { return }
        lastStatus = data
        try? data.write(to: folder.appendingPathComponent(".nowplaying.json"), options: .atomic)
    }
}

/// Mac Kumandası: the iPod controls what plays on the Mac. While the screen is open the app keeps
/// a ".macremote" flag in the music folder; the Mac's iPod Müzik app sees it, picks up each
/// command file (".mac-*") at once and keeps ".macstatus.json" up to date. Commands: toggle, next,
/// prev, vol <0-100>.
final class MacRemote: ObservableObject {
    struct Status: Decodable {
        let volume: Int
        let muted: Bool
        let title: String
        let artist: String
        /// The player the title comes from (Müzik, Spotify), or "".
        let app: String
        /// Whether the Mac is putting out sound at all.
        let playing: Bool
        /// When the Mac last wrote this; older than a few seconds means it isn't listening.
        let time: TimeInterval
    }

    @Published private(set) var status: Status?
    @Published private(set) var connected = false
    /// Shown at once when the wheel turns, before the Mac confirms it.
    @Published private(set) var volume = 0.0

    private let folder = SongLibrary.folder
    private var timer: Timer?
    private var sent = 0
    private var volumeTurned = Date.distantPast

    private var flag: URL { folder.appendingPathComponent(".macremote") }

    func open() {
        FileManager.default.createFile(atPath: flag.path, contents: nil)
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.read() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        try? FileManager.default.removeItem(at: flag)
    }

    func send(_ command: String) {
        sent += 1
        // Written under another name and then renamed, so the Mac never reads half a command.
        let temp = folder.appendingPathComponent(".mactmp-\(sent)")
        let name = String(format: ".mac-%.0f-%d", Date().timeIntervalSince1970 * 1000, sent)
        guard (try? Data(command.utf8).write(to: temp)) != nil else { return }
        try? FileManager.default.moveItem(at: temp, to: folder.appendingPathComponent(name))
    }

    /// One wheel tick is 2 points: fine enough to set it exactly, and a quick turn still goes far.
    func changeVolume(by delta: Int) -> Bool {
        let new = min(max(volume + Double(delta) * 2, 0), 100)
        guard new != volume else { return false }
        volume = new
        volumeTurned = Date()
        send("vol \(Int(new.rounded()))")
        return true
    }

    private func read() {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".macstatus.json")),
              let new = try? JSONDecoder().decode(Status.self, from: data) else {
            connected = false
            return
        }
        status = new
        connected = Date().timeIntervalSince1970 - new.time < 6
        // While the wheel is turning, the Mac's answer lags behind it.
        if Date().timeIntervalSince(volumeTurned) > 1.5 { volume = Double(new.volume) }
    }
}
