import Combine
import MediaPlayer

/// Puts the iPod's song into the Mac's own Now Playing (Control Center, the media keys, AirPods
/// taps), like any player app. macOS hands the media keys to whichever app played last, so while
/// the iPod plays they control it, and once the Mac plays something itself (Safari, Music…) they
/// go there instead. When the iPod is gone the entry is cleared.
final class MacNowPlaying {
    private let phone: Phone
    private var cancellable: AnyCancellable?

    init(phone: Phone) {
        self.phone = phone
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send("toggle", ifPlaying: nil) ?? .commandFailed }
        commands.playCommand.addTarget { [weak self] _ in self?.send("toggle", ifPlaying: false) ?? .commandFailed }
        commands.pauseCommand.addTarget { [weak self] _ in self?.send("toggle", ifPlaying: true) ?? .commandFailed }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.send("next", ifPlaying: nil) ?? .commandFailed }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.send("prev", ifPlaying: nil) ?? .commandFailed }
        cancellable = phone.$nowPlaying.receive(on: DispatchQueue.main).sink { [weak self] in self?.update($0) }
    }

    /// The phone only knows "toggle", so play and pause send it only when it changes something.
    private func send(_ command: String, ifPlaying: Bool?) -> MPRemoteCommandHandlerStatus {
        guard phone.found else { return .noActionableNowPlayingItem }
        if let wanted = ifPlaying, phone.nowPlaying?.playing != wanted { return .success }
        phone.command(command)
        return .success
    }

    private func update(_ status: Phone.NowPlaying?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let status = status, !status.title.isEmpty else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: status.title,
            MPMediaItemPropertyArtist: status.artist,
            MPMediaItemPropertyPlaybackDuration: status.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: status.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: status.playing ? 1.0 : 0.0,
        ]
        center.playbackState = status.playing ? .playing : .paused
    }
}
