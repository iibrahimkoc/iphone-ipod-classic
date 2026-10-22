import SwiftUI
import MediaPlayer
import AVFoundation
import notify

enum MenuAction {
    case push(String, () -> [MenuItem])
    case play([Song], Int)
    case shuffleAll
    case nowPlaying
    case clickVolume
    case coverFlow
    case live(LiveList)
    case run(() -> Void)
}

/// Lists rebuilt from live system state on every render.
enum LiveList {
    case settings
    case battery
    case bluetooth
    case wifi

    var title: String {
        switch self {
        case .settings: return "Ayarlar"
        case .battery: return "Pil"
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
    /// Index of the album in front.
    case coverFlow(Int)
    /// Rebuilt from live state on every render, so only the position is stored.
    case live(LiveList, selection: Int, top: Int)
    case password(PasswordEntry)
    case chess
    case game
}

/// What the bar at the bottom of Now Playing shows; the center button cycles through them,
/// and the wheel adjusts the one on screen (volume for the progress bar).
enum NowPlayingMode: CaseIterable {
    case progress, shuffle, repeatMode
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
    @Published private(set) var nowPlayingMode = NowPlayingMode.progress
    /// The time shown in place of "iPod" on the main menu.
    @Published private(set) var clock = IPodModel.time()
    private var clockTimer: Timer?

    let player = PlayerController()
    let volume = VolumeController()
    let bluetooth = BluetoothController()
    let wifi = WiFiController()
    let airplane = AirplaneController()
    let battery = BatteryMonitor()
    let library = SongLibrary()
    let chess = ChessGame()
    /// The emulated game on screen.
    private(set) var emulator: Emulator?
    private(set) lazy var remote = RemoteControl(player: player, volume: volume)
    private(set) lazy var sleepTimer = SleepTimer { [unowned self] done in self.player.fadeOutAndPause(completion: done) }
    /// Albums for Cover Flow, loaded when it opens.
    private(set) var albums: [Album] = []
    private(set) lazy var route = AudioRouteController(player: player)
    private var hideHUD: DispatchWorkItem?

    /// What quarantine changed, so charging can put it back.
    private var preQuarantine: (airplane: Bool, brightness: CGFloat)?
    private var lockTimer: DispatchWorkItem?

    init() {
        stack = [.list(mainMenu())]
        startClock()
        _ = remote
        battery.onQuarantineChange = { [unowned self] on in on ? self.enterQuarantine() : self.leaveQuarantine() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [unowned self] _ in
            if self.battery.quarantine { self.scheduleLock() } else { Brightness.set(self.brightness) }
        }
    }

    private static func time() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    /// Updates the clock on each minute boundary.
    private func startClock() {
        clock = Self.time()
        let nextMinute = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + nextMinute + 0.05) { [weak self] in
            self?.clock = Self.time()
            self?.clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self?.clock = Self.time() }
        }
    }

    // MARK: Battery quarantine

    private func enterQuarantine() {
        preQuarantine = (airplane.enabled, UIScreen.main.brightness)
        player.pause()
        airplane.setEnabled(true)
        Brightness.set(0.05)
        scheduleLock()
    }

    private func leaveQuarantine() {
        lockTimer?.cancel()
        guard let saved = preQuarantine else { return }
        preQuarantine = nil
        if !saved.airplane { airplane.setEnabled(false) }
        brightness = Double(saved.brightness)
        Brightness.set(brightness)
    }

    /// Asks the kiosk tweak to turn the screen off a few seconds after it was woken.
    private func scheduleLock() {
        lockTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.battery.quarantine == true else { return }
            notify_post("com.ibrahimkoc.ipod.lock")
        }
        lockTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    var current: Screen { stack[stack.count - 1] }

    var title: String {
        switch current {
        case .list(let list): return stack.count == 1 ? clock : list.title
        case .nowPlaying: return "Şimdi Çalıyor"
        case .clickVolume: return "Tık Sesi"
        case .coverFlow: return "Cover Flow"
        case .live(let kind, _, _): return kind.title
        case .password: return "Şifre"
        case .chess: return "Satranç"
        case .game: return emulator?.title ?? "Oyun"
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
            case .battery: items = batteryItems()
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
                self.library.reload()
                self.stack = [.list(self.mainMenu())]
            }
        }
    }

    // MARK: Wheel input

    /// A battery warning on screen takes the next wheel input, like an alert would.
    private func consumeWarning() -> Bool {
        if battery.quarantine { return true }
        guard battery.warning != nil else { return false }
        battery.dismissWarning()
        return true
    }

    func scroll(_ delta: Int) {
        if consumeWarning() { return }
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
            switch nowPlayingMode {
            case .progress:
                adjustVolume(by: Double(delta) / 16)
            case .shuffle:
                guard player.shuffle != (delta > 0) else { return }
                player.shuffle = delta > 0
            case .repeatMode:
                let modes = PlayerController.RepeatMode.allCases
                let new = modes[min(max(player.repeatMode.rawValue + delta.signum(), 0), modes.count - 1)]
                guard new != player.repeatMode else { return }
                player.repeatMode = new
            }
            Feedback.tick()
        case .clickVolume:
            let new = min(max((clickVolume + Double(delta) * 0.05) * 20, 0), 20).rounded() / 20
            guard new != clickVolume else { return }
            clickVolume = new
            Feedback.volume = new
            Feedback.tick()
        case .coverFlow(let index):
            let new = min(max(index + delta, 0), max(albums.count - 1, 0))
            guard new != index else { return }
            stack[stack.count - 1] = .coverFlow(new)
            Feedback.tick()
        case .password(var entry):
            let count = PasswordEntry.options.count
            entry.index = ((entry.index + delta) % count + count) % count
            stack[stack.count - 1] = .password(entry)
            Feedback.tick()
        case .chess:
            if chess.scroll(delta) { Feedback.tick() }
        case .game:
            break
        }
    }

    func select() {
        if consumeWarning() { return }
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
        if case .chess = current {
            Feedback.tick()
            chess.select()
            return
        }
        if case .game = current { return }
        if case .nowPlaying = current {
            Feedback.tick()
            let modes = NowPlayingMode.allCases
            nowPlayingMode = modes[(modes.firstIndex(of: nowPlayingMode)! + 1) % modes.count]
            return
        }
        if case .coverFlow(let index) = current {
            guard albums.indices.contains(index) else { return }
            Feedback.tick()
            let album = albums[index]
            stack.append(.list(ListScreen(title: album.name, items: songsMenu(album.songs))))
            return
        }
        guard let list = currentList, list.items.indices.contains(list.selection) else { return }
        Feedback.tick()
        switch list.items[list.selection].action {
        case .push(let title, let makeItems):
            stack.append(.list(ListScreen(title: title, items: makeItems())))
        case .play(let items, let index):
            player.play(items, from: index)
            showNowPlaying()
        case .shuffleAll:
            player.shuffleAll(library.songs)
            showNowPlaying()
        case .nowPlaying:
            showNowPlaying()
        case .clickVolume:
            stack.append(.clickVolume)
        case .coverFlow:
            albums = library.albums(of: library.songs)
            stack.append(.coverFlow(0))
        case .live(let kind):
            stack.append(.live(kind, selection: 0, top: 0))
            switch kind {
            case .settings: airplane.refresh()
            case .battery: break
            case .bluetooth: bluetooth.startScanning()
            case .wifi: wifi.startScanning()
            }
        case .run(let run):
            run()
        }
    }

    func menu() {
        if consumeWarning() { return }
        Feedback.tick()
        // A picked-up chess piece goes back first.
        if case .chess = current, chess.back() { return }
        guard stack.count > 1 else { return }
        switch stack.removeLast() {
        case .live(let kind, _, _):
            switch kind {
            case .settings, .battery: break
            case .bluetooth: bluetooth.stopScanning()
            case .wifi: wifi.stopScanning()
            }
        case .chess:
            chess.close()
        case .game:
            emulator?.stop()
            emulator = nil
        default:
            break
        }
    }

    private func showNowPlaying() {
        nowPlayingMode = .progress
        stack.append(.nowPlaying)
    }

    // MARK: Screen swipes

    func adjustVolume(by delta: Double) {
        volume.change(by: Float(delta))
        show(.volume)
    }

    func adjustBrightness(by delta: Double) {
        brightness = min(max(brightness + delta, 0), 1)
        Brightness.set(brightness)
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
            MenuItem(title: "Oyunlar", action: .push("Oyunlar") { [unowned self] in self.gamesMenu() }),
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
        items.append(MenuItem(title: "Karıştır", action: .run { [unowned self] in self.player.shuffle.toggle() },
                              detail: player.shuffle ? "Şarkılar" : "Kapalı"))
        items.append(MenuItem(title: "Tekrarla", action: .run { [unowned self] in
            let modes = PlayerController.RepeatMode.allCases
            self.player.repeatMode = modes[(self.player.repeatMode.rawValue + 1) % modes.count]
        }, detail: player.repeatMode.name))
        items.append(MenuItem(title: "Uyku Zamanlayıcısı", action: .push("Uyku Zamanlayıcısı") { [unowned self] in
            self.sleepTimerItems()
        }, detail: sleepTimer.remainingMinutes.map { "\($0) dk" } ?? "Kapalı"))
        items.append(MenuItem(title: "Pil", action: .live(.battery), detail: batterySummary))
        items.append(MenuItem(title: "Tık Sesi", action: .clickVolume))
        return items
    }

    /// "%64 · ~7 sa" for the Settings row.
    private var batterySummary: String {
        guard battery.level >= 0 else { return "" }
        let percent = "%\(Int((battery.level * 100).rounded()))"
        guard let estimate = battery.estimate, !battery.charging else { return percent }
        return "\(percent) · ~\(Int(estimate / 3600)) sa"
    }

    private func batteryItems() -> [MenuItem] {
        let nothing = MenuAction.run {}
        let level = battery.level >= 0 ? "%\(Int((battery.level * 100).rounded()))" : "?"
        let estimate = battery.estimate.map(Self.duration) ?? "Hesaplanıyor…"
        return [
            MenuItem(title: "Şarj", action: nothing, detail: level),
            MenuItem(title: "Durum", action: nothing, detail: battery.charging ? "Şarj oluyor" : "Pilde"),
            MenuItem(title: battery.charging ? "Dolmasına" : "Tahmini süre", action: nothing, detail: estimate),
            MenuItem(title: "Düşük Güç Modu", action: .run {
                LowPowerMode.set(!ProcessInfo.processInfo.isLowPowerModeEnabled)
            }, detail: ProcessInfo.processInfo.isLowPowerModeEnabled ? "Açık" : "Kapalı"),
            MenuItem(title: "Pil Testi", action: .run { [unowned self] in self.battery.cycleSimulation() },
                     detail: battery.simulation.map { BatteryMonitor.simulations[$0].name } ?? "Kapalı"),
        ] + headphoneItems()
    }

    private func headphoneItems() -> [MenuItem] {
        guard let levels = route.headphoneBattery else { return [] }
        let name = levels.name.localizedCaseInsensitiveContains("airpods") ? "AirPods" : "Kulaklık"
        let parts = [("Sol", levels.left), ("Sağ", levels.right), ("Kutu", levels.case)]
            .compactMap { title, level in level.map { (title, $0) } }
        if parts.isEmpty, let single = levels.single {
            return [MenuItem(title: name, action: .run {}, detail: "%\(single)")]
        }
        return parts.map { MenuItem(title: "\(name) \($0.0)", action: .run {}, detail: "%\($0.1)") }
    }

    /// "7 sa 20 dk" / "45 dk".
    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "~\(minutes / 60) sa \(minutes % 60) dk" : "~\(max(minutes, 1)) dk"
    }

    /// Choosing an entry starts the timer (or turns it off) and goes back to Settings.
    private func sleepTimerItems() -> [MenuItem] {
        let off = MenuItem(title: "Kapalı", action: .run { [unowned self] in
            self.sleepTimer.cancel()
            self.menu()
        })
        return [off] + SleepTimer.choices.map { minutes in
            MenuItem(title: "\(minutes) dakika", action: .run { [unowned self] in
                self.sleepTimer.start(minutes: minutes)
                self.menu()
            })
        }
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

    private func gamesMenu() -> [MenuItem] {
        [
            MenuItem(title: "Satranç", action: .push("Satranç") { [unowned self] in self.chessMenu() }),
            MenuItem(title: "Doom", action: .push("Doom") { [unowned self] in self.consoleMenu(.doom) }),
            MenuItem(title: "Mega Drive", action: .push("Mega Drive") { [unowned self] in self.consoleMenu(.megaDrive) }),
        ]
    }

    /// The console's games. One with a saved place asks whether to carry on or start over.
    private func consoleMenu(_ console: Console) -> [MenuItem] {
        console.games().map { game in
            let name = console.title(game)
            guard console.hasSave(game) else {
                return MenuItem(title: name, action: .run { [unowned self] in self.openGame(game, on: console) })
            }
            return MenuItem(title: name, action: .push(name) { [unowned self] in
                [
                    MenuItem(title: "Devam Et", action: .run { [unowned self] in self.openGame(game, on: console) }),
                    MenuItem(title: "Baştan Başla", action: .run { [unowned self] in
                        console.deleteSave(game)
                        self.openGame(game, on: console)
                    }),
                ]
            }, detail: "Kayıtlı")
        }
    }

    private func openGame(_ game: URL, on console: Console) {
        guard let emulator = Emulator(console: console, game: game) else { return }
        player.pause()
        self.emulator = emulator
        stack.append(.game)
    }

    /// A tap on the game's screen presses that half's button for a few frames, so the game sees it.
    func tapScreen(left: Bool) {
        guard let emulator = emulator else { return }
        let button: UInt32 = 1 << UInt32(left ? emulator.console.leftTap : emulator.console.rightTap)
        emulator.tapped |= button
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { emulator.tapped &= ~button }
    }

    func setPad(_ buttons: UInt32) {
        emulator?.pad = buttons
    }

    private func chessMenu() -> [MenuItem] {
        var items: [MenuItem] = []
        if chess.canResume {
            items.append(MenuItem(title: "Devam Et", action: .run { [unowned self] in self.openChess() },
                                  detail: chess.level.title))
        }
        items.append(MenuItem(title: "Yeni Oyun", action: .push("Yeni Oyun") { [unowned self] in
            ChessGame.Level.allCases.map { level in
                MenuItem(title: level.title, action: .run { [unowned self] in self.openChess(level) })
            }
        }))
        return items
    }

    /// Starts a new game at `level`, or carries on with the saved one.
    private func openChess(_ level: ChessGame.Level? = nil) {
        if let level = level { chess.start(level) } else { chess.open() }
        stack.append(.chess)
    }

    private func musicMenu() -> [MenuItem] {
        [
            MenuItem(title: "Cover Flow", action: .coverFlow),
            MenuItem(title: "Çalma Listeleri", action: .push("Çalma Listeleri") { [unowned self] in self.playlistsMenu() }),
            MenuItem(title: "Sanatçılar", action: .push("Sanatçılar") { [unowned self] in self.artistsMenu() }),
            MenuItem(title: "Albümler", action: .push("Albümler") { [unowned self] in
                self.albumsMenu(self.library.albums(of: self.library.songs))
            }),
            MenuItem(title: "Şarkılar", action: .push("Şarkılar") { [unowned self] in self.songsMenu(self.library.songs) }),
        ]
    }

    private func playlistsMenu() -> [MenuItem] {
        (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }.map { playlist in
            let name = playlist.name ?? "Çalma Listesi"
            return MenuItem(title: name, action: .push(name) { [unowned self] in self.songsMenu(self.library.songs(in: playlist)) })
        }
    }

    private func artistsMenu() -> [MenuItem] {
        library.artists(of: library.songs).map { artist in
            MenuItem(title: artist.name, action: .push(artist.name) { [unowned self] in
                let all = MenuItem(title: "Tüm Şarkılar", action: .push(artist.name) { [unowned self] in self.songsMenu(artist.songs) })
                return [all] + self.albumsMenu(self.library.albums(of: artist.songs))
            })
        }
    }

    private func albumsMenu(_ albums: [Album]) -> [MenuItem] {
        albums.map { album in
            MenuItem(title: album.name, action: .push(album.name) { [unowned self] in self.songsMenu(album.songs) })
        }
    }

    private func songsMenu(_ songs: [Song]) -> [MenuItem] {
        songs.enumerated().map { index, song in
            MenuItem(title: song.title, action: .play(songs, index))
        }
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
    /// Battery levels of the connected Bluetooth headphones.
    @Published private(set) var headphoneBattery: HeadphoneBattery.Levels?
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
        // Route-change notifications only arrive while the app's audio session is active, so poll as well.
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
        // Read even on the speaker: with both earbuds back in the open case, audio leaves the
        // AirPods but that is exactly when the case's level is reported.
        let levels = HeadphoneBattery.read()
        if levels != headphoneBattery { headphoneBattery = levels }
    }
}

/// Reads accessory batteries from the private BatteryCenter framework, the source of the
/// Batteries widget. AirPods report each earbud and the case as separate entries.
enum HeadphoneBattery {
    struct Levels: Equatable {
        var name = ""
        var left: Int?
        var right: Int?
        var `case`: Int?
        /// Headphones that report one level for both sides.
        var single: Int?

        /// The lower earbud, which is the one that runs out first.
        var lowest: Int? { [left, right].compactMap { $0 }.min() ?? single }
    }

    private static let controller: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter", RTLD_NOW)
        // Every call is checked first: a selector missing on this iOS version would crash the app.
        guard let cls = NSClassFromString("BCBatteryDeviceController") as? NSObject.Type else { return nil }
        let shared = NSSelectorFromString("sharedInstance")
        if cls.responds(to: shared) { return cls.perform(shared)?.takeUnretainedValue() as? NSObject }
        return cls.init()
    }()

    static func read() -> Levels? {
        let connected = NSSelectorFromString("connectedDevices")
        guard let controller = controller, controller.responds(to: connected),
              let devices = controller.perform(connected)?.takeUnretainedValue() as? [NSObject] else { return nil }
        var levels = Levels()
        // Each part's identifier is the device address plus "-Left", "-Right", "-Case" or "-Single".
        for device in devices where !bool(device, "isInternal") {
            let percent = integer(device, "percentCharge")
            guard percent >= 0, let identifier = string(device, "identifier") else { continue }
            levels.name = string(device, "groupName") ?? levels.name
            if identifier.hasSuffix("-Left") { levels.left = percent }
            else if identifier.hasSuffix("-Right") { levels.right = percent }
            else if identifier.hasSuffix("-Case") { levels.case = percent }
            else { levels.single = percent }
        }
        return [levels.left, levels.right, levels.case, levels.single].allSatisfy { $0 == nil } ? nil : levels
    }

    private static func string(_ object: NSObject, _ selector: String) -> String? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        return object.perform(sel)?.takeUnretainedValue() as? String
    }

    private static func bool(_ object: NSObject, _ selector: String) -> Bool {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel)
    }

    private static func integer(_ object: NSObject, _ selector: String) -> Int {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return -1 }
        typealias Fn = @convention(c) (NSObject, Selector) -> Int
        return unsafeBitCast(object.method(for: sel), to: Fn.self)(object, sel)
    }
}

final class VolumeController: ObservableObject {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
    @Published private(set) var level = AVAudioSession.sharedInstance().outputVolume

    func change(by delta: Float) {
        set(currentLevel + delta)
    }

    func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let value = min(max(value, 0), 1)
        slider.value = value
        slider.sendActions(for: .valueChanged)
        level = value
    }

    /// The side buttons change the volume behind our back, so read the slider rather than `level`.
    var currentLevel: Float {
        view.subviews.compactMap { $0 as? UISlider }.first?.value ?? level
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

/// The system brightness, as Control Center sets it. UIScreen.brightness is only an override: UIKit
/// remembers the level from before the app's first change and puts it back when the screen turns off,
/// so it is used only when the private call is missing.
enum Brightness {
    private typealias SetFn = @convention(c) (Float, Int32) -> Void
    private static let setSystem: SetFn? = {
        let lib = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW)
        guard let lib = lib, let pointer = dlsym(lib, "BKSDisplayBrightnessSet") else { return nil }
        return unsafeBitCast(pointer, to: SetFn.self)
    }()

    static func set(_ level: Double) {
        if let setSystem = setSystem {
            setSystem(Float(level), 1)
        } else {
            UIScreen.main.brightness = CGFloat(level)
        }
    }
}
