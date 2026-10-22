import SwiftUI
import AVFoundation

/// A system the app plays through a libretro core. The cores are bundled in the app's cores
/// folder (see build.sh) and loaded when one of their games opens; each system has its own folder
/// of games under iPodOyun.
struct Console {
    static let root = URL(fileURLWithPath: "/var/mobile/Media/iPodOyun")

    static let megaDrive = Console(
        name: "Mega Drive", core: "genesis_plus_gx_libretro_ios.dylib", folder: root.appendingPathComponent("MegaDrive"),
        extensions: ["md", "gen", "bin", "smd", "68k", "sgd", "sms", "gg"],
        center: RETRO_DEVICE_ID_JOYPAD_B, leftTap: RETRO_DEVICE_ID_JOYPAD_START, rightTap: RETRO_DEVICE_ID_JOYPAD_START,
        help: "Tekerlek: yön · Orta: zıpla\nEkrana dokun: Start · Uzun bas: çık")

    /// PrBoom's classic layout: the D-pad walks and turns, X fires, A uses (doors, switches) and
    /// Start is the menu, where A and X also confirm.
    static let doom = Console(
        name: "Doom", core: "prboom_libretro_ios.dylib", folder: root.appendingPathComponent("Doom"),
        extensions: ["wad"],
        titles: ["doom1.wad": "Doom: 1. Bölüm", "freedoom1.wad": "Freedoom: Phase 1", "freedoom2.wad": "Freedoom: Phase 2"],
        center: RETRO_DEVICE_ID_JOYPAD_X, leftTap: RETRO_DEVICE_ID_JOYPAD_A, rightTap: RETRO_DEVICE_ID_JOYPAD_START,
        help: "Tekerlek: yürü, dön · Orta: ateş\nSol: kapı aç · Sağ: menü · Uzun bas: çık")

    let name: String
    let core: String
    let folder: URL
    let extensions: Set<String>
    /// Menu names for known files.
    var titles: [String: String] = [:]
    /// What the wheel's center and a tap on the left or right half of the screen press.
    let center: Int32
    let leftTap: Int32
    let rightTap: Int32
    let help: String

    /// The games in the folder, by name. prboom.wad is the engine's own data, not a game.
    func games() -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) && $0.lastPathComponent.lowercased() != "prboom.wad" }
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }

    func title(_ game: URL) -> String {
        titles[game.lastPathComponent.lowercased()] ?? game.deletingPathExtension().lastPathComponent
    }

    func hasSave(_ game: URL) -> Bool {
        FileManager.default.fileExists(atPath: stateFile(game).path)
    }

    func deleteSave(_ game: URL) {
        try? FileManager.default.removeItem(at: stateFile(game))
    }

    func stateFile(_ game: URL) -> URL {
        folder.appendingPathComponent("." + game.deletingPathExtension().lastPathComponent + ".state")
    }

    func sramFile(_ game: URL) -> URL {
        folder.appendingPathComponent("." + game.deletingPathExtension().lastPathComponent + ".srm")
    }
}

/// The libretro functions of a core opened with dlopen.
private struct Core {
    let handle: UnsafeMutableRawPointer
    let setEnvironment: @convention(c) (retro_environment_t?) -> Void
    let setVideoRefresh: @convention(c) (retro_video_refresh_t?) -> Void
    let setAudioSample: @convention(c) (retro_audio_sample_t?) -> Void
    let setAudioSampleBatch: @convention(c) (retro_audio_sample_batch_t?) -> Void
    let setInputPoll: @convention(c) (retro_input_poll_t?) -> Void
    let setInputState: @convention(c) (retro_input_state_t?) -> Void
    let initialize: @convention(c) () -> Void
    let deinitialize: @convention(c) () -> Void
    let loadGame: @convention(c) (UnsafePointer<retro_game_info>?) -> Bool
    let unloadGame: @convention(c) () -> Void
    let avInfo: @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void
    let run: @convention(c) () -> Void
    let serializeSize: @convention(c) () -> Int
    let serialize: @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool
    let unserialize: @convention(c) (UnsafeRawPointer?, Int) -> Bool
    let memoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer?
    let memorySize: @convention(c) (UInt32) -> Int

    init?(path: String) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let setEnvironment: @convention(c) (retro_environment_t?) -> Void = symbol("retro_set_environment"),
              let setVideoRefresh: @convention(c) (retro_video_refresh_t?) -> Void = symbol("retro_set_video_refresh"),
              let setAudioSample: @convention(c) (retro_audio_sample_t?) -> Void = symbol("retro_set_audio_sample"),
              let setAudioSampleBatch: @convention(c) (retro_audio_sample_batch_t?) -> Void = symbol("retro_set_audio_sample_batch"),
              let setInputPoll: @convention(c) (retro_input_poll_t?) -> Void = symbol("retro_set_input_poll"),
              let setInputState: @convention(c) (retro_input_state_t?) -> Void = symbol("retro_set_input_state"),
              let initialize: @convention(c) () -> Void = symbol("retro_init"),
              let deinitialize: @convention(c) () -> Void = symbol("retro_deinit"),
              let loadGame: @convention(c) (UnsafePointer<retro_game_info>?) -> Bool = symbol("retro_load_game"),
              let unloadGame: @convention(c) () -> Void = symbol("retro_unload_game"),
              let avInfo: @convention(c) (UnsafeMutablePointer<retro_system_av_info>?) -> Void = symbol("retro_get_system_av_info"),
              let run: @convention(c) () -> Void = symbol("retro_run"),
              let serializeSize: @convention(c) () -> Int = symbol("retro_serialize_size"),
              let serialize: @convention(c) (UnsafeMutableRawPointer?, Int) -> Bool = symbol("retro_serialize"),
              let unserialize: @convention(c) (UnsafeRawPointer?, Int) -> Bool = symbol("retro_unserialize"),
              let memoryData: @convention(c) (UInt32) -> UnsafeMutableRawPointer? = symbol("retro_get_memory_data"),
              let memorySize: @convention(c) (UInt32) -> Int = symbol("retro_get_memory_size")
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.setEnvironment = setEnvironment
        self.setVideoRefresh = setVideoRefresh
        self.setAudioSample = setAudioSample
        self.setAudioSampleBatch = setAudioSampleBatch
        self.setInputPoll = setInputPoll
        self.setInputState = setInputState
        self.initialize = initialize
        self.deinitialize = deinitialize
        self.loadGame = loadGame
        self.unloadGame = unloadGame
        self.avInfo = avInfo
        self.run = run
        self.serializeSize = serializeSize
        self.serialize = serialize
        self.unserialize = unserialize
        self.memoryData = memoryData
        self.memorySize = memorySize
    }
}

/// A game running on its console's core. Leaving it saves its state, so it carries on where it
/// was left. libretro calls back into plain C functions, so they reach the one running game
/// through `current`.
final class Emulator: NSObject {
    private static var current: Emulator?
    /// The system and save directory handed to the core: the console's folder.
    private static var directory: UnsafeMutablePointer<CChar>?

    /// Held buttons as a bit per RETRO_DEVICE_ID_JOYPAD_* id: the wheel's, and the screen taps'.
    var pad: UInt32 = 0
    var tapped: UInt32 = 0
    /// The picture; its layer gets each frame.
    let view = UIView()
    let console: Console
    let title: String
    private let game: URL
    private let core: Core
    private var pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555.rawValue
    private var pixels: [UInt32] = []
    private var link: CADisplayLink?
    private let audio = AudioOutput()
    private var resignObserver: NSObjectProtocol?

    init?(console: Console, game: URL) {
        guard Self.current == nil, let core = Core(path: Bundle.main.bundlePath + "/cores/" + console.core) else { return nil }
        self.console = console
        self.game = game
        self.core = core
        title = console.title(game)
        super.init()
        Self.current = self
        free(Self.directory)
        Self.directory = strdup(console.folder.path)

        core.setEnvironment { command, data in Emulator.environment(command, data) }
        core.setVideoRefresh { data, width, height, pitch in
            Emulator.current?.show(data, width: Int(width), height: Int(height), pitch: pitch)
        }
        core.setAudioSample { left, right in
            var frame = [left, right]
            Emulator.current?.audio.push(&frame, frames: 1)
        }
        core.setAudioSampleBatch { data, frames in
            if let data = data { Emulator.current?.audio.push(data, frames: frames) }
            return frames
        }
        core.setInputPoll {}
        core.setInputState { port, device, _, id in
            guard port == 0, device == UInt32(RETRO_DEVICE_JOYPAD), let game = Emulator.current, id < 32 else { return 0 }
            return (game.pad | game.tapped) & (1 << id) != 0 ? 1 : 0
        }
        core.initialize()
        let loaded = game.path.withCString { path -> Bool in
            var info = retro_game_info(path: path, data: nil, size: 0, meta: nil)
            return core.loadGame(&info)
        }
        guard loaded else {
            core.deinitialize()
            dlclose(core.handle)
            Self.current = nil
            return nil
        }
        var av = retro_system_av_info()
        core.avInfo(&av)
        loadSaves()

        view.backgroundColor = .black
        view.layer.contentsGravity = .resizeAspect
        view.layer.magnificationFilter = .nearest
        // Taps go through to the screen's SwiftUI gestures (the buttons, long press to leave).
        view.isUserInteractionEnabled = false
        audio.start(rate: av.timing.sample_rate)
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        self.link = link
        // The app may not come back (a reboot, a crash), so the place is kept whenever it leaves the screen.
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.save() }
    }

    /// Saves where the game is and shuts the core down.
    func stop() {
        link?.invalidate()
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
        save()
        audio.stop()
        core.unloadGame()
        core.deinitialize()
        dlclose(core.handle)
        Self.current = nil
    }

    @objc private func frame() {
        core.run()
    }

    // MARK: Saves

    private func save() {
        let size = core.serializeSize()
        if size > 0 {
            var state = Data(count: size)
            let saved = state.withUnsafeMutableBytes { core.serialize($0.baseAddress, size) }
            if saved { try? state.write(to: console.stateFile(game), options: .atomic) }
        }
        // Battery-backed saves too, in case the state file is ever lost.
        let sramSize = core.memorySize(UInt32(RETRO_MEMORY_SAVE_RAM))
        if sramSize > 0, let sram = core.memoryData(UInt32(RETRO_MEMORY_SAVE_RAM)) {
            try? Data(bytes: sram, count: sramSize).write(to: console.sramFile(game), options: .atomic)
        }
    }

    private func loadSaves() {
        let sramSize = core.memorySize(UInt32(RETRO_MEMORY_SAVE_RAM))
        if sramSize > 0, let sram = core.memoryData(UInt32(RETRO_MEMORY_SAVE_RAM)),
           let saved = try? Data(contentsOf: console.sramFile(game)) {
            saved.copyBytes(to: sram.assumingMemoryBound(to: UInt8.self), count: min(saved.count, sramSize))
        }
        if let state = try? Data(contentsOf: console.stateFile(game)) {
            _ = state.withUnsafeBytes { core.unserialize($0.baseAddress, state.count) }
        }
    }

    // MARK: Core callbacks

    private static func environment(_ command: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch Int32(command) {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            guard let format = data?.load(as: UInt32.self), format <= RETRO_PIXEL_FORMAT_RGB565.rawValue else { return false }
            current?.pixelFormat = format
            return true
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = UnsafePointer(directory)
            return true
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            data?.assumingMemoryBound(to: Bool.self).pointee = true
            return true
        default:
            return false
        }
    }

    /// Turns the core's frame into 32-bit pixels for the layer. A nil frame repeats the last one.
    private func show(_ data: UnsafeRawPointer?, width: Int, height: Int, pitch: Int) {
        guard let data = data, width > 0, height > 0 else { return }
        if pixels.count != width * height { pixels = Array(repeating: 0, count: width * height) }
        let format = pixelFormat
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0 ..< height {
                let row = data + y * pitch
                let base = y * width
                switch format {
                case RETRO_PIXEL_FORMAT_XRGB8888.rawValue:
                    let source = row.assumingMemoryBound(to: UInt32.self)
                    for x in 0 ..< width { out[base + x] = source[x] | 0xFF00_0000 }
                case RETRO_PIXEL_FORMAT_RGB565.rawValue:
                    let source = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0 ..< width {
                        let p = UInt32(source[x])
                        let r = (p >> 11) & 31, g = (p >> 5) & 63, b = p & 31
                        out[base + x] = 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 2 | g >> 4) << 8) | (b << 3 | b >> 2)
                    }
                default:
                    let source = row.assumingMemoryBound(to: UInt16.self)
                    for x in 0 ..< width {
                        let p = UInt32(source[x])
                        let r = (p >> 10) & 31, g = (p >> 5) & 31, b = p & 31
                        out[base + x] = 0xFF00_0000 | ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2)
                    }
                }
            }
        }
        let bytes = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.contents = image
        CATransaction.commit()
    }
}

/// Plays the core's 16-bit stereo samples. They go into a ring buffer that the audio thread
/// drains; anything beyond ~90 ms is dropped so the sound stays in step with the picture.
private final class AudioOutput {
    private let engine = AVAudioEngine()
    private var ring = [Int16](repeating: 0, count: 1 << 15)
    private var read = 0
    private var write = 0
    private let lock = NSLock()
    private let maxBuffered = 4096 * 2

    func start(rate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let mask = self.ring.count - 1
            self.lock.lock()
            for frame in 0 ..< Int(frameCount) {
                if self.read != self.write {
                    left[frame] = Float(self.ring[self.read]) / 32768
                    right[frame] = Float(self.ring[self.read + 1]) / 32768
                    self.read = (self.read + 2) & mask
                } else {
                    left[frame] = 0
                    right[frame] = 0
                }
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    func stop() {
        engine.stop()
    }

    func push(_ samples: UnsafePointer<Int16>, frames: Int) {
        let mask = ring.count - 1
        lock.lock()
        for index in 0 ..< frames * 2 {
            ring[write] = samples[index]
            write = (write + 1) & mask
        }
        let buffered = (write - read + ring.count) & mask
        if buffered > maxBuffered { read = (write - maxBuffered + ring.count) & mask }
        lock.unlock()
    }
}

/// While a game runs the click wheel is its gamepad: where a finger is on the ring is the D-pad
/// (eight directions) and the center is the console's main button (jump, fire). Several fingers
/// work at once, so running and jumping go together.
struct GamepadOverlay: UIViewRepresentable {
    let center: Int32
    let onChange: (UInt32) -> Void

    func makeUIView(context: Context) -> GamepadView {
        let view = GamepadView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: GamepadView, context: Context) {
        view.centerButton = center
        view.onChange = onChange
    }
}

final class GamepadView: UIView {
    var centerButton = RETRO_DEVICE_ID_JOYPAD_B
    var onChange: ((UInt32) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { update(event) }

    private func update(_ event: UIEvent?) {
        let size = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var buttons: UInt32 = 0
        func press(_ id: Int32) { buttons |= 1 << UInt32(id) }
        for touch in event?.allTouches ?? [] where touch.view === self && touch.phase != .ended && touch.phase != .cancelled {
            let point = touch.location(in: self)
            let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
            let distance = hypot(dx, dy)
            if distance < Double(size) * 0.19 {
                press(centerButton)
                continue
            }
            // Eight 45° sectors, starting with right and going clockwise (screen y grows downward).
            let angle = (atan2(dy, dx) + 2 * .pi + .pi / 8).truncatingRemainder(dividingBy: 2 * .pi)
            switch Int(angle / (.pi / 4)) {
            case 0: press(RETRO_DEVICE_ID_JOYPAD_RIGHT)
            case 1: press(RETRO_DEVICE_ID_JOYPAD_RIGHT); press(RETRO_DEVICE_ID_JOYPAD_DOWN)
            case 2: press(RETRO_DEVICE_ID_JOYPAD_DOWN)
            case 3: press(RETRO_DEVICE_ID_JOYPAD_DOWN); press(RETRO_DEVICE_ID_JOYPAD_LEFT)
            case 4: press(RETRO_DEVICE_ID_JOYPAD_LEFT)
            case 5: press(RETRO_DEVICE_ID_JOYPAD_LEFT); press(RETRO_DEVICE_ID_JOYPAD_UP)
            case 6: press(RETRO_DEVICE_ID_JOYPAD_UP)
            default: press(RETRO_DEVICE_ID_JOYPAD_UP); press(RETRO_DEVICE_ID_JOYPAD_RIGHT)
            }
        }
        onChange?(buttons)
    }
}

/// The game's picture, with the controls shown for a few seconds when it opens. A tap on the
/// left or right half presses that side's button; a long press anywhere leaves.
struct GameScreen: View {
    let game: Emulator
    let onTap: (_ left: Bool) -> Void
    let onLeave: () -> Void
    @State private var showsHelp = true

    var body: some View {
        GameLayer(view: game.view)
            .overlay(HStack(spacing: 0) {
                half(left: true)
                half(left: false)
            })
            .overlay(Group {
                if showsHelp {
                    Text(game.console.help)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false)
                }
            })
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { showsHelp = false }
            }
    }

    private func half(left: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onTap(left) }
            .onLongPressGesture(minimumDuration: 0.8, perform: onLeave)
    }
}

private struct GameLayer: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
