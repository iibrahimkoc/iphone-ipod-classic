import UIKit
import MediaPlayer
import AVFoundation

/// Plays Songs with AVPlayer in the app itself (the system Music player can't play the app's
/// own files), with background audio, lock screen info and headphone/AirPods controls.
final class PlayerController: ObservableObject {
    @Published private(set) var item: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queueIndex = 0
    @Published private(set) var queueCount = 0

    private let player = AVPlayer()
    private var queue: [Song] = []
    private var observers: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            self?.elapsed = seconds.isFinite ? seconds : 0
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isPlaying = player.timeControlStatus != .paused
                self?.updateNowPlaying()
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self = self, note.object as? AVPlayerItem === self.player.currentItem else { return }
            self.advance()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .began { self?.pause() }
        })
        setUpRemoteCommands()
    }

    var duration: TimeInterval { item?.duration ?? 0 }

    func play(_ songs: [Song], from index: Int) {
        guard songs.indices.contains(index) else { return }
        // Music synced through Finder used to play in the system player; make sure it is quiet.
        MPMusicPlayerController.systemMusicPlayer.pause()
        queue = songs
        queueCount = songs.count
        load(index)
        resume()
    }

    func shuffle(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        play(songs.shuffled(), from: 0)
    }

    func togglePlay() {
        Feedback.tick()
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
    }

    func next() {
        Feedback.tick()
        guard queueIndex + 1 < queue.count else { return }
        load(queueIndex + 1)
        resume()
    }

    func previous() {
        Feedback.tick()
        if elapsed > 3 || queueIndex == 0 {
            player.seek(to: .zero)
        } else {
            load(queueIndex - 1)
            resume()
        }
    }

    private func resume() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    /// At the end of a song: the next one, or stop at the end of the list like the iPod.
    private func advance() {
        if queueIndex + 1 < queue.count {
            load(queueIndex + 1)
            resume()
        } else {
            player.pause()
            player.seek(to: .zero)
        }
    }

    private func load(_ index: Int) {
        queueIndex = index
        item = queue[index]
        elapsed = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: queue[index].url))
        updateNowPlaying()
    }

    // MARK: Lock screen and remote controls

    private func updateNowPlaying() {
        guard let song = item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistName,
            MPMediaItemPropertyAlbumTitle: song.albumName,
            MPMediaItemPropertyPlaybackDuration: song.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = song.artwork(size: 600) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        commands.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.isPlaying ? self.pause() : self.resume()
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600))
            return .success
        }
    }
}
