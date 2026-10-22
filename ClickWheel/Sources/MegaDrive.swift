import SwiftUI
import AVFoundation

/// Mega Drive (and Master System / Game Gear) games through Genesis Plus GX, a libretro core
/// linked into the app (see build.sh). The ROMs are the files in `folder`. Leaving a game saves
/// its state, so it carries on where it was left. libretro calls back into plain C functions, so
/// they reach the one running game through `current`.
final class MegaDrive: NSObject {
    static let folder = URL(fileURLWithPath: "/var/mobile/Media/iPodOyun")
    private static let extensions: Set<String> = ["md", "gen", "bin", "smd", "68k", "sgd", "sms", "gg"]
    private static let folderPath = UnsafePointer(strdup(folder.path)!)
    private static var current: MegaDrive?

    /// The ROMs in the folder, by name.
    static func games() -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func hasSave(_ rom: URL) -> Bool {
        FileManager.default.fileExists(atPath: stateFile(rom).path)
    }

    static func deleteSave(_ rom: URL) {
        try? FileManager.default.removeItem(at: stateFile(rom))
    }

    private static func stateFile(_ rom: URL) -> URL {
        folder.appendingPathComponent("." + rom.deletingPathExtension().lastPathComponent + ".state")
    }

    private static func sramFile(_ rom: URL) -> URL {
        folder.appendingPathComponent("." + rom.deletingPathExtension().lastPathComponent + ".srm")
    }

    /// Held buttons as a bit per RETRO_DEVICE_ID_JOYPAD_* id: the wheel's, and Start from the screen.
    var pad: UInt32 = 0
    var start = false
    /// The picture; its layer gets each frame.
    let view = UIView()
    let title: String
    private let rom: URL
    private var pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555.rawValue
    private var pixels: [UInt32] = []
    private var link: CADisplayLink?
    private let audio = AudioOutput()
    private var resignObserver: NSObjectProtocol?

    init?(rom: URL) {
        guard Self.current == nil else { return nil }
        self.rom = rom
        title = rom.deletingPathExtension().lastPathComponent
        super.init()
        Self.current = self

        retro_set_environment { command, data in MegaDrive.environment(command, data) }
        retro_set_video_refresh { data, width, height, pitch in
            MegaDrive.current?.show(data, width: Int(width), height: Int(height), pitch: pitch)
        }
        retro_set_audio_sample { left, right in
            var frame = [left, right]
            MegaDrive.current?.audio.push(&frame, frames: 1)
        }
        retro_set_audio_sample_batch { data, frames in
            if let data = data { MegaDrive.current?.audio.push(data, frames: frames) }
            return frames
        }
        retro_set_input_poll {}
        retro_set_input_state { port, device, _, id in
            guard port == 0, device == UInt32(RETRO_DEVICE_JOYPAD), let game = MegaDrive.current, id < 32 else { return 0 }
            var buttons = game.pad
            if game.start { buttons |= 1 << UInt32(RETRO_DEVICE_ID_JOYPAD_START) }
            return buttons & (1 << id) != 0 ? 1 : 0
        }
        retro_init()
        let loaded = rom.path.withCString { path -> Bool in
            var info = retro_game_info(path: path, data: nil, size: 0, meta: nil)
            return retro_load_game(&info)
        }
        guard loaded else {
            retro_deinit()
            Self.current = nil
            return nil
        }
        var av = retro_system_av_info()
        retro_get_system_av_info(&av)
        loadSaves()

        view.backgroundColor = .black
        view.layer.contentsGravity = .resizeAspect
        view.layer.magnificationFilter = .nearest
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
        retro_unload_game()
        retro_deinit()
        Self.current = nil
    }

    @objc private func frame() {
        retro_run()
    }

    // MARK: Saves

    private func save() {
        let size = retro_serialize_size()
        if size > 0 {
            var state = Data(count: size)
            let saved = state.withUnsafeMutableBytes { retro_serialize($0.baseAddress, size) }
            if saved { try? state.write(to: Self.stateFile(rom), options: .atomic) }
        }
        // Battery-backed saves too, in case the state file is ever lost.
        let sramSize = retro_get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        if sramSize > 0, let sram = retro_get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)) {
            try? Data(bytes: sram, count: sramSize).write(to: Self.sramFile(rom), options: .atomic)
        }
    }

    private func loadSaves() {
        let sramSize = retro_get_memory_size(UInt32(RETRO_MEMORY_SAVE_RAM))
        if sramSize > 0, let sram = retro_get_memory_data(UInt32(RETRO_MEMORY_SAVE_RAM)),
           let saved = try? Data(contentsOf: Self.sramFile(rom)) {
            saved.copyBytes(to: sram.assumingMemoryBound(to: UInt8.self), count: min(saved.count, sramSize))
        }
        if let state = try? Data(contentsOf: Self.stateFile(rom)) {
            _ = state.withUnsafeBytes { retro_unserialize($0.baseAddress, state.count) }
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
            data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = folderPath
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
/// (eight directions) and the center is B, the jump button. Several fingers work at once, so
/// running and jumping go together.
struct GamepadOverlay: UIViewRepresentable {
    let onChange: (UInt32) -> Void

    func makeUIView(context: Context) -> GamepadView {
        let view = GamepadView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: GamepadView, context: Context) {
        view.onChange = onChange
    }
}

final class GamepadView: UIView {
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
                press(RETRO_DEVICE_ID_JOYPAD_B)
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

/// The game's picture, with the controls shown for a few seconds when it opens.
struct GameScreen: View {
    let game: MegaDrive
    @State private var showsHelp = true

    var body: some View {
        GameLayer(view: game.view)
            .overlay(Group {
                if showsHelp {
                    Text("Tekerlek: yön · Orta: zıpla\nEkrana dokun: Start · Uzun bas: çık")
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            })
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { showsHelp = false }
            }
    }
}

private struct GameLayer: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
