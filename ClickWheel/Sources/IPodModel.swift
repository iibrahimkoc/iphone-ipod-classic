import SwiftUI
import MediaPlayer
import AVFoundation

enum MenuAction {
    case push(String, () -> [MenuItem])
    case play([MPMediaItem], Int)
    case shuffleAll
    case nowPlaying
    case clickVolume
    case live(LiveList)
    case run(() -> Void)
}

/// Lists rebuilt from live system state on every render.
enum LiveList {
    case settings
    case bluetooth
    case wifi

    var title: String {
        switch self {
        case .settings: return "Ayarlar"
        case .bluetooth: return "Bluetooth"
        case .wifi: return "Wi-Fi"
        }
    }
}

/// Typing a Wi-Fi password with the wheel: scrolling picks a character, the center adds it.
struct PasswordEntry {
    static let commands = ["Bağlan", "Sil"]
    static let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .-_@!?#$%&*+=/:;,'\"()").map(String.init)
    static let options = commands + characters

    let network: WiFiController.Network
    var text = ""
    var index = commands.count
}

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: MenuAction
    /// Gray status text on the right, e.g. "Bağlı".
    var detail: String? = nil

    var showsChevron: Bool {
        switch action {
        case .play, .run: return false
        default: return true
        }
    }
}

struct ListScreen {
    let title: String
    let items: [MenuItem]
    var selection = 0
    var top = 0
}

enum Screen {
    case list(ListScreen)
    case nowPlaying
    case clickVolume
    /// Rebuilt from live state on every render, so only the position is stored.
    case live(LiveList, selection: Int, top: Int)
    case password(PasswordEntry)
}

/// What the screen's swipe gestures (or the wheel on Now Playing) are adjusting.
enum HUD {
    case volume
    case brightness
}

/// Navigation state for the iPod UI: a stack of screens driven by wheel input.
final class IPodModel: ObservableObject {
    static let visibleRows = 7

    @Published private(set) var stack: [Screen] = []
    @Published private(set) var authorized = MPMediaLibrary.authorizationStatus() == .authorized
    @Published private(set) var hud: HUD?
    @Published private(set) var brightness = Double(UIScreen.main.brightness)
    @Published private(set) var clickVolume = Feedback.volume

    let player = PlayerController()
    let volume = VolumeController()
    let bluetooth = BluetoothController()
    let wifi = WiFiController()
    let airplane = AirplaneController()
    private(set) lazy var route = AudioRouteController(player: player)
    private var hideHUD: DispatchWorkItem?

    init() {
        stack = [.list(mainMenu())]
    }

    var current: Screen { stack[stack.count - 1] }

    var title: String {
        switch current {
        case .list(let list): return list.title
        case .nowPlaying: return "Şimdi Çalıyor"
        case .clickVolume: return "Tık Sesi"
        case .live(let kind, _, _): return kind.title
        case .password: return "Şifre"
        }
    }

    /// The list on screen, for both static menus and the live lists.
    var currentList: ListScreen? {
        switch current {
        case .list(let list):
            return list
        case .live(let kind, let selection, let top):
            let items: [MenuItem]
            switch kind {
            case .settings: items = settingsItems()
            case .bluetooth: items = bluetoothItems()
            case .wifi: items = wifiItems()
            }
            let clamped = min(selection, max(items.count - 1, 0))
            return ListScreen(title: kind.title, items: items, selection: clamped, top: min(top, clamped))
        default:
            return nil
        }
    }

    func requestAccess() {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.authorized = status == .authorized
                self.stack = [.list(self.mainMenu())]
            }
        }
    }

    // MARK: Wheel input

    func scroll(_ delta: Int) {
        switch current {
        case .list, .live:
            guard var list = currentList, !list.items.isEmpty else { return }
            let new = min(max(list.selection + delta, 0), list.items.count - 1)
            guard new != list.selection else { return }
            list.selection = new
            if new < list.top {
                list.top = new
            } else if new >= list.top + Self.visibleRows {
                list.top = new - Self.visibleRows + 1
            }
            if case .live(let kind, _, _) = current {
                stack[stack.count - 1] = .live(kind, selection: list.selection, top: list.top)
            } else {
                stack[stack.count - 1] = .list(list)
            }
            Feedback.tick()
        case .nowPlaying:
            adjustVolume(by: Double(delta) / 16)
            Feedback.tick()
        case .clickVolume:
            let new = min(max((clickVolume + Double(delta) * 0.05) * 20, 0), 20).rounded() / 20
            guard new != clickVolume else { return }
            clickVolume = new
            Feedback.volume = new
            Feedback.tick()
        case .password(var entry):
            let count = PasswordEntry.options.count
            entry.index = ((entry.index + delta) % count + count) % count
            stack[stack.count - 1] = .password(entry)
            Feedback.tick()
        }
    }

    func select() {
        if case .password(var entry) = current {
            Feedback.tick()
            switch PasswordEntry.options[entry.index] {
            case "Bağlan":
                wifi.join(entry.network, password: entry.text)
                stack.removeLast()
                return
            case "Sil":
                if !entry.text.isEmpty { entry.text.removeLast() }
            case let character:
                entry.text += character
            }
            stack[stack.count - 1] = .password(entry)
            return
        }
        guard let list = currentList, list.items.indices.contains(list.selection) else { return }
        Feedback.tick()
        switch list.items[list.selection].action {
        case .push(let title, let makeItems):
            stack.append(.list(ListScreen(title: title, items: makeItems())))
        case .play(let items, let index):
            player.play(items, from: index)
            stack.append(.nowPlaying)
        case .shuffleAll:
            player.shuffleAll()
            stack.append(.nowPlaying)
        case .nowPlaying:
            stack.append(.nowPlaying)
        case .clickVolume:
            stack.append(.clickVolume)
        case .live(let kind):
            stack.append(.live(kind, selection: 0, top: 0))
            switch kind {
            case .settings: airplane.refresh()
            case .bluetooth: bluetooth.startScanning()
            case .wifi: wifi.startScanning()
            }
        case .run(let run):
            run()
        }
    }

    func menu() {
        Feedback.tick()
        guard stack.count > 1 else { return }
        if case .live(let kind, _, _) = stack.removeLast() {
            switch kind {
            case .settings: break
            case .bluetooth: bluetooth.stopScanning()
            case .wifi: wifi.stopScanning()
            }
        }
    }

    // MARK: Screen swipes

    func adjustVolume(by delta: Double) {
        volume.change(by: Float(delta))
        show(.volume)
    }

    func adjustBrightness(by delta: Double) {
        brightness = min(max(brightness + delta, 0), 1)
        UIScreen.main.brightness = CGFloat(brightness)
        show(.brightness)
    }

    private func show(_ kind: HUD) {
        hud = kind
        hideHUD?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hud = nil }
        hideHUD = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Menus

    private func mainMenu() -> ListScreen {
        ListScreen(title: "iPod", items: [
            MenuItem(title: "Müzik", action: .push("Müzik") { [unowned self] in self.musicMenu() }),
            MenuItem(title: "Şarkıları Karıştır", action: .shuffleAll),
            MenuItem(title: "Şimdi Çalıyor", action: .nowPlaying),
            MenuItem(title: "Ayarlar", action: .live(.settings)),
        ])
    }

    private func settingsItems() -> [MenuItem] {
        var items: [MenuItem] = []
        if airplane.available {
            // Airplane mode also switches off Wi-Fi and Bluetooth; iOS remembers if they are turned back on.
            items.append(MenuItem(title: "Uçak Modu", action: .run { [unowned self] in
                self.airplane.setEnabled(!self.airplane.enabled)
            }, detail: airplane.enabled ? "Açık" : "Kapalı"))
        }
        items.append(MenuItem(title: "Wi-Fi", action: .live(.wifi), detail: wifi.powered ? wifi.current ?? "Açık" : "Kapalı"))
        items.append(MenuItem(title: "Bluetooth", action: .live(.bluetooth), detail: bluetooth.powered ? "Açık" : "Kapalı"))
        items.append(MenuItem(title: "Tık Sesi", action: .clickVolume))
        return items
    }

    private func wifiItems() -> [MenuItem] {
        guard wifi.available else {
            return [MenuItem(title: "Wi-Fi kullanılamıyor", action: .run {})]
        }
        let power = MenuItem(title: "Wi-Fi", action: .run { [unowned self] in
            self.wifi.setPowered(!self.wifi.powered)
        }, detail: wifi.powered ? "Açık" : "Kapalı")
        guard wifi.powered else { return [power] }

        var items = [power]
        if let current = wifi.current {
            items.append(MenuItem(title: "✓ \(current)", action: .run {}, detail: "Bağlı"))
        }
        for network in wifi.networks where network.ssid != wifi.current {
            let status: String
            if wifi.joining == network.ssid {
                status = "Bağlanıyor…"
            } else if wifi.failed == network.ssid {
                status = "Hata"
            } else if network.known {
                status = "Kayıtlı"
            } else {
                status = network.secure ? "🔒" : ""
            }
            items.append(MenuItem(title: network.ssid, action: .run { [unowned self] in
                if network.secure && !network.known {
                    self.stack.append(.password(PasswordEntry(network: network)))
                } else {
                    self.wifi.join(network)
                }
            }, detail: status))
        }
        if let ip = wifi.ipAddress {
            items.append(MenuItem(title: "IP Adresi", action: .run {}, detail: ip))
        }
        if let current = wifi.current {
            items.append(MenuItem(title: "Unut: \(current)", action: .run { [unowned self] in self.wifi.forgetCurrent() }))
        }
        return items
    }

    private func bluetoothItems() -> [MenuItem] {
        guard bluetooth.available else {
            return [MenuItem(title: "Bluetooth kullanılamıyor", action: .run {})]
        }
        let power = MenuItem(title: "Bluetooth", action: .run { [unowned self] in
            self.bluetooth.setPowered(!self.bluetooth.powered)
        }, detail: bluetooth.powered ? "Açık" : "Kapalı")
        guard bluetooth.powered else { return [power] }

        let devices = bluetooth.devices.map { device -> MenuItem in
            let status: String
            if bluetooth.connecting == device.address {
                status = "Bağlanıyor…"
            } else if device.connected {
                status = "Bağlı"
            } else {
                status = device.paired ? "" : "Yeni"
            }
            return MenuItem(title: device.name, action: .run { [unowned self] in self.bluetooth.toggle(device) },
                            detail: status)
        }
        let forget = bluetooth.devices.filter(\.paired).map { device in
            MenuItem(title: "Unut: \(device.name)", action: .run { [unowned self] in self.bluetooth.forget(device) })
        }
        return [power] + devices + forget
    }

    private func musicMenu() -> [MenuItem] {
        [
            MenuItem(title: "Çalma Listeleri", action: .push("Çalma Listeleri") { [unowned self] in self.playlistsMenu() }),
            MenuItem(title: "Sanatçılar", action: .push("Sanatçılar") { [unowned self] in self.artistsMenu() }),
            MenuItem(title: "Albümler", action: .push("Albümler") { [unowned self] in self.albumsMenu(MPMediaQuery.albums()) }),
            MenuItem(title: "Şarkılar", action: .push("Şarkılar") { [unowned self] in self.songsMenu(MPMediaQuery.songs().items ?? []) }),
        ]
    }

    private func playlistsMenu() -> [MenuItem] {
        (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }.map { playlist in
            let name = playlist.name ?? "Çalma Listesi"
            return MenuItem(title: name, action: .push(name) { [unowned self] in self.songsMenu(playlist.items) })
        }
    }

    private func artistsMenu() -> [MenuItem] {
        (MPMediaQuery.artists().collections ?? []).map { artist in
            let name = artist.representativeItem?.artist ?? "Bilinmeyen Sanatçı"
            let artistID = artist.representativeItem?.artistPersistentID ?? 0
            return MenuItem(title: name, action: .push(name) { [unowned self] in
                let albums = MPMediaQuery.albums()
                albums.addFilterPredicate(MPMediaPropertyPredicate(
                    value: NSNumber(value: artistID),
                    forProperty: MPMediaItemPropertyArtistPersistentID))
                let all = MenuItem(title: "Tüm Şarkılar", action: .push(name) { [unowned self] in self.songsMenu(artist.items) })
                return [all] + self.albumsMenu(albums)
            })
        }
    }

    private func albumsMenu(_ query: MPMediaQuery) -> [MenuItem] {
        (query.collections ?? []).map { album in
            let name = album.representativeItem?.albumTitle ?? "Bilinmeyen Albüm"
            return MenuItem(title: name, action: .push(name) { [unowned self] in self.songsMenu(album.items) })
        }
    }

    private func songsMenu(_ items: [MPMediaItem]) -> [MenuItem] {
        items.enumerated().map { index, item in
            MenuItem(title: item.title ?? "Bilinmeyen", action: .play(items, index))
        }
    }
}

/// Wraps the system music player so playback keeps going and shows on the lock screen.
final class PlayerController: ObservableObject {
    private let player = MPMusicPlayerController.systemMusicPlayer

    @Published private(set) var item: MPMediaItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queueIndex = 0
    @Published private(set) var queueCount = 0

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init() {
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        refresh()
    }

    var duration: TimeInterval { item?.playbackDuration ?? 0 }

    func play(_ items: [MPMediaItem], from index: Int) {
        guard items.indices.contains(index) else { return }
        player.shuffleMode = .off
        player.setQueue(with: MPMediaItemCollection(items: items))
        player.nowPlayingItem = items[index]
        queueCount = items.count
        player.play()
    }

    func shuffleAll() {
        let items = (MPMediaQuery.songs().items ?? []).shuffled()
        guard !items.isEmpty else { return }
        play(items, from: 0)
    }

    func togglePlay() {
        Feedback.tick()
        isPlaying ? player.pause() : player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        Feedback.tick()
        player.skipToNextItem()
    }

    func previous() {
        Feedback.tick()
        if player.currentPlaybackTime > 3 {
            player.skipToBeginning()
        } else {
            player.skipToPreviousItem()
        }
    }

    private func refresh() {
        item = player.nowPlayingItem
        isPlaying = player.playbackState == .playing
        queueIndex = player.indexOfNowPlayingItem
        updateElapsed()
    }

    private func updateElapsed() {
        let time = player.currentPlaybackTime
        elapsed = time.isFinite ? time : 0
    }
}

/// Changes the system volume through a hidden MPVolumeView, which also suppresses the volume HUD.
/// Tracks where audio is going (AirPods, headphones or the speaker) and pauses playback when
/// headphones disconnect, so music never suddenly plays out loud from the speaker.
final class AudioRouteController: ObservableObject {
    enum Output {
        case airpods
        case headphones
        case speaker

        var symbol: String {
            switch self {
            case .airpods: return "airpods"
            case .headphones: return "headphones"
            case .speaker: return "speaker.wave.2.fill"
            }
        }
    }

    @Published private(set) var output = Output.speaker
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var onHeadphonesLost: (() -> Void)?

    init(player: PlayerController) {
        onHeadphonesLost = { [weak player] in player?.pause() }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update()
        }
        // Route-change notifications aren't delivered reliably to an app without an active audio
        // session (the music plays in the system player), so poll as well.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    private func update() {
        let previous = output
        defer {
            // Headphones went away: keep the music off the speaker.
            if previous != .speaker && output == .speaker { onHeadphonesLost?() }
        }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if let port = outputs.first(where: { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }) {
            output = port.portName.localizedCaseInsensitiveContains("airpods") ? .airpods : .headphones
        } else if outputs.contains(where: { $0.portType == .headphones || $0.portType == .usbAudio }) {
            output = .headphones
        } else {
            output = .speaker
        }
    }
}

final class VolumeController: ObservableObject {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
    @Published private(set) var level = AVAudioSession.sharedInstance().outputVolume

    func change(by delta: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let value = min(max(slider.value + delta, 0), 1)
        slider.value = value
        slider.sendActions(for: .valueChanged)
        level = value
    }
}

/// The iPhone 6s has no UIFeedbackGenerator haptics, so the wheel plays its own click.
/// It is played as a system sound, which follows the ringer volume instead of the media
/// volume, so turning the music up or down with the side buttons doesn't change the click.
/// (Like all system sounds it is muted by the silent switch.)
enum Feedback {
    private static let volumeKey = "clickVolume"
    private static var soundID: SystemSoundID = 0

    /// Amplitude of the click sample; persisted so the chosen level survives relaunches.
    static var volume: Double {
        get { UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.12 }
        set {
            UserDefaults.standard.set(newValue, forKey: volumeKey)
            // System sounds have no gain control, so the sample is regenerated at the new level.
            if soundID != 0 {
                AudioServicesDisposeSystemSoundID(soundID)
                soundID = 0
            }
        }
    }

    static func tick() {
        if soundID == 0, let url = writeClick(volume: volume) {
            AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        }
        AudioServicesPlaySystemSound(soundID)
    }

    /// A short, sharp tick: a 3.2 kHz tone mixed with noise under a fast exponential decay.
    private static func writeClick(volume: Double) -> URL? {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(rate * 0.012)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0 ..< Int(frames) {
            let t = Double(i) / rate
            let envelope = exp(-t * 900)
            let tone = sin(2 * .pi * 3200 * t)
            samples[i] = Float((0.6 * tone + 0.4 * Double.random(in: -1 ... 1)) * envelope * volume)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("click-\(Int((volume * 100).rounded())).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return url
    }
}
