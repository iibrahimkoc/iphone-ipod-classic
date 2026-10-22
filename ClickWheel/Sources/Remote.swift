import AVFoundation

/// Lets the Mac's iPod Müzik app control playback over SSH. The Mac drops a ".command" file in
/// the music folder (watched, so it's handled at once), and the app keeps ".nowplaying.json"
/// there up to date for the Mac to read.
///
/// Commands: toggle, next, prev, vol <0-100>
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

    private func readCommand() {
        let file = folder.appendingPathComponent(".command")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        switch parts.first {
        case "toggle"?: player.togglePlay()
        case "next"?: player.next()
        case "prev"?: player.previous()
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
