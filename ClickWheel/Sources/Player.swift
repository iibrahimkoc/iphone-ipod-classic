import UIKit
import MediaPlayer
import AVFoundation

/// Plays Songs with AVPlayer in the app itself (the system Music player can't play the app's
/// own files), with background audio, lock screen info and headphone/AirPods controls.
final class PlayerController: ObservableObject {
    enum RepeatMode: Int, CaseIterable {
        case off, one, all

        var name: String {
            switch self {
            case .off: return "Kapalı"
            case .one: return "Bir"
            case .all: return "Tümü"
            }
        }
    }

    /// Songs: play in random order. Persisted, like the iPod's settings.
    @Published var shuffle = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet {
            UserDefaults.standard.set(shuffle, forKey: "shuffle")
            if shuffle != oldValue { reorderQueue() }
        }
    }
    @Published var repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeat")) ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }

    @Published private(set) var item: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queueIndex = 0
    @Published private(set) var queueCount = 0

    /// Liked and disliked songs; every shuffle leans on them.
    let ratings = Ratings()

    private let player = AVPlayer()
    /// When playback was last started. Starting can pull the AirPods over from the Mac, and while
    /// they move the route passes through the speaker and iOS may report an interruption; neither
    /// should stop the song that was just asked for.
    private var resumedAt = Date.distantPast

    /// True for a few seconds after playback starts, while the headphones may still be switching over.
    var justResumed: Bool { Date().timeIntervalSince(resumedAt) < 4 }
    private var queue: [Song] = []
    /// The list as chosen, so turning shuffle off restores its order.
    private var original: [Song] = []
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
            guard let self = self else { return }
            let info = note.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .began {
                if !self.justResumed { self.pause() }
            } else if type == .ended, self.justResumed {
                // The interruption was the headphones switching over: carry on.
                self.resume()
            }
        })
        setUpRemoteCommands()
    }

    var duration: TimeInterval { item?.duration ?? 0 }

    func play(_ songs: [Song], from index: Int) {
        guard songs.indices.contains(index) else { return }
        // Music synced through Finder used to play in the system player; make sure it is quiet.
        MPMusicPlayerController.systemMusicPlayer.pause()
        original = songs
        // With shuffle on, the chosen song plays first and the rest follow in random order.
        if shuffle {
            start([songs[index]] + ratings.shuffled(songs.enumerated().filter { $0.offset != index }.map(\.element)), at: 0)
        } else {
            start(songs, at: index)
        }
    }

    /// "Şarkıları Karıştır": the whole library in random order, whatever the shuffle setting,
    /// leaning toward liked songs and leaving out disliked ones.
    func shuffleAll(_ songs: [Song]) {
        let order = ratings.shuffled(songs)
        guard !order.isEmpty else { return }
        MPMusicPlayerController.systemMusicPlayer.pause()
        original = order
        start(order, at: 0)
    }

    private func start(_ songs: [Song], at index: Int) {
        queue = songs
        queueCount = songs.count
        load(index)
        resume()
    }

    /// Fades the music out over a few seconds, then pauses (for the sleep timer).
    func fadeOutAndPause(completion: @escaping () -> Void) {
        let steps = 20
        for step in 1 ... steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.4) { [weak self] in
                guard let self = self else { return }
                self.player.volume = Float(steps - step) / Float(steps)
                if step == steps {
                    self.player.pause()
                    self.player.volume = 1
                    completion()
                }
            }
        }
    }

    private func reorderQueue() {
        guard let current = item, !original.isEmpty else { return }
        if shuffle {
            queue = [current] + ratings.shuffled(original.filter { $0 !== current })
            queueIndex = 0
            queueCount = queue.count
        } else {
            queue = original
            queueIndex = original.firstIndex { $0 === current } ?? 0
            queueCount = queue.count
        }
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
        if queueIndex + 1 < queue.count {
            load(queueIndex + 1)
        } else if repeatMode == .all, !queue.isEmpty {
            load(0)
        } else {
            return
        }
        resume()
    }

    func previous() {
        Feedback.tick()
        if elapsed > 3 || (queueIndex == 0 && repeatMode != .all) {
            player.seek(to: .zero)
        } else {
            load(queueIndex == 0 ? queue.count - 1 : queueIndex - 1)
            resume()
        }
    }

    private func resume() {
        guard player.currentItem != nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        resumedAt = Date()
        player.play()
    }

    /// At the end of a song: the same one again, the next one, back to the start (Repeat All,
    /// reshuffled if shuffling), or stop at the end of the list like the iPod.
    private func advance() {
        if repeatMode == .one {
            player.seek(to: .zero)
            resume()
        } else if queueIndex + 1 < queue.count {
            load(queueIndex + 1)
            resume()
        } else if repeatMode == .all, !queue.isEmpty {
            if shuffle {
                queue = ratings.shuffled(original)
                queueCount = queue.count
            }
            guard !queue.isEmpty else { return player.pause() }
            load(0)
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
