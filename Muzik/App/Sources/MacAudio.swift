import AudioToolbox
import CoreAudio
import Foundation

/// Whether the Mac itself is playing sound, read from its output device (CoreAudio's "running
/// somewhere": some app has audio going to it). The Mac's Now Playing can't be read since macOS
/// 15.4, and claiming it pulls the AirPods over from the phone, so the keys are routed by this.
final class MacAudio {
    /// When the Mac's own audio last started; distantPast if it hasn't since launch.
    private(set) var lastStarted = Date.distantPast
    private(set) var playing = false
    private var timer: Timer?

    init() {
        // Already running at launch counts as old, so it doesn't outrank the iPod.
        playing = Self.outputRunning()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let now = Self.outputRunning()
        if now && !playing { lastStarted = Date() }
        playing = now
    }

    /// The output volume, 0…1, as the volume keys set it.
    static var volume: Float {
        guard let device = defaultOutput() else { return 0 }
        return property(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput) ?? 0
    }

    static var muted: Bool {
        guard let device = defaultOutput() else { return false }
        let mute: UInt32 = property(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) ?? 0
        return mute != 0
    }

    /// Sets the volume (unmuting above 0) on the output device.
    static func setVolume(_ level: Float) {
        guard let device = defaultOutput() else { return }
        var volume = min(max(level, 0), 1)
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &volume)
        var mute: UInt32 = volume > 0 ? 0 : 1
        set(device, kAudioDevicePropertyMute, &mute)
    }

    private static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    private static func outputRunning() -> Bool {
        guard let device = defaultOutput() else { return false }
        let running: UInt32 = property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
        return running != 0
    }

    private static func defaultOutput() -> AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}
