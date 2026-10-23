import SwiftUI

/// Ana menü › Fener: the rear flash, whose tone goes from the white LED to the amber one (Torch).
final class Flashlight: ObservableObject {
    /// The flash's tones, by the amber LED's share, with a color for the screen to show.
    static let tones: [(name: String, warm: Int, color: Color)] = [
        ("Beyaz", 0, Color(red: 0.92, green: 0.96, blue: 1)),
        ("Doğal", 25, Color(red: 1, green: 0.97, blue: 0.9)),
        ("Sıcak", 50, Color(red: 1, green: 0.88, blue: 0.68)),
        ("Mum", 75, Color(red: 1, green: 0.76, blue: 0.45)),
        ("Amber", 100, Color(red: 1, green: 0.62, blue: 0.2)),
    ]
    /// The center steps through these: off, then dimmest to brightest.
    static let levels = [0, 25, 50, 100]

    @Published private(set) var tone = UserDefaults.standard.integer(forKey: "flashlightTone") {
        didSet { UserDefaults.standard.set(tone, forKey: "flashlightTone") }
    }
    /// Index into `levels`.
    @Published private(set) var level = 0
    /// The flash couldn't be had, e.g. while the camera has it.
    @Published private(set) var failed = false

    private let torch = Torch()

    var isOn: Bool { level > 0 }

    func changeTone(by delta: Int) -> Bool {
        let new = min(max(tone + delta.signum(), 0), Self.tones.count - 1)
        guard new != tone else { return false }
        tone = new
        if isOn { apply() }
        return true
    }

    func cycleLevel() {
        level = (level + 1) % Self.levels.count
        apply()
    }

    func off() {
        guard isOn || failed else { return }
        level = 0
        apply()
    }

    private func apply() {
        if level == 0 {
            torch.stop()
            failed = false
        } else {
            failed = !torch.setLevel(Float(Self.levels[level]) / 100, warm: Int32(Self.tones[tone].warm))
            if failed { level = 0 }
        }
    }
}

/// The flash screen: its tone as a lamp, and how bright it is.
struct FlashlightView: View {
    @ObservedObject var flashlight: Flashlight

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let tone = Flashlight.tones[flashlight.tone]
            VStack(spacing: h * 0.05) {
                ZStack {
                    Circle()
                        .fill(flashlight.isOn ? tone.color : Color(white: 0.85))
                        .shadow(color: flashlight.isOn ? tone.color : .clear, radius: h * 0.08)
                    Circle().stroke(Color(white: 0.55), lineWidth: 1)
                    Image(systemName: flashlight.isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: h * 0.16))
                        .foregroundColor(Color(white: flashlight.isOn ? 0.25 : 0.5))
                }
                .frame(width: h * 0.42, height: h * 0.42)
                Text(flashlight.isOn ? "\(tone.name) · %\(Flashlight.levels[flashlight.level])" : tone.name)
                    .font(.system(size: h * 0.09, weight: .bold))
                HStack(spacing: 4) {
                    ForEach(Flashlight.tones.indices, id: \.self) { index in
                        Capsule()
                            .fill(Flashlight.tones[index].color)
                            .overlay(Capsule().stroke(index == flashlight.tone ? Color.black : Color(white: 0.6),
                                                      lineWidth: index == flashlight.tone ? 2 : 0.5))
                            .frame(width: h * 0.11, height: h * 0.05)
                    }
                }
                Text(flashlight.failed ? "Flaş kullanılamıyor" : "Çark: ton · Orta: aç, parlaklık")
                    .font(.system(size: h * 0.06))
                    .foregroundColor(flashlight.failed ? .red : .gray)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
