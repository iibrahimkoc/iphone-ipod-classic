import SwiftUI

/// Ana menü › Fener: the rear flash, whose tone goes from the white LED to the amber one (Torch),
/// and the screen as a light of any color.
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
    static let colors: [(name: String, color: Color)] = [
        ("Kırmızı", .red), ("Turuncu", .orange), ("Sarı", .yellow), ("Yeşil", .green),
        ("Turkuaz", Color(red: 0, green: 0.85, blue: 0.85)), ("Mavi", .blue), ("Mor", .purple),
        ("Pembe", Color(red: 1, green: 0.4, blue: 0.7)), ("Beyaz", .white), ("Gökkuşağı", .white),
    ]
    static var rainbow: Int { colors.count - 1 }

    @Published private(set) var tone = UserDefaults.standard.integer(forKey: "flashlightTone") {
        didSet { UserDefaults.standard.set(tone, forKey: "flashlightTone") }
    }
    /// Index into `levels`.
    @Published private(set) var level = 0
    /// The flash couldn't be had, e.g. while the camera has it.
    @Published private(set) var failed = false
    @Published private(set) var color = UserDefaults.standard.integer(forKey: "flashlightColor") {
        didSet { UserDefaults.standard.set(color, forKey: "flashlightColor") }
    }

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

    func changeColor(by delta: Int) -> Bool {
        let count = Self.colors.count
        color = ((color + delta.signum()) % count + count) % count
        return true
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

/// The screen light's color now: the chosen one, or the rainbow's, which goes round every 12 s.
struct ScreenLight: View {
    let color: Int

    var body: some View {
        if color == Flashlight.rainbow {
            TimelineView(.animation) { context in
                let hue = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12
                Color(hue: hue, saturation: 1, brightness: 1)
            }
        } else {
            Flashlight.colors[color].color
        }
    }
}

/// Renkli Ekran behind the screen and the wheel.
struct ScreenLightBackground: View {
    @ObservedObject var flashlight: Flashlight

    var body: some View {
        ScreenLight(color: flashlight.color)
    }
}

/// The screen light inside the iPod's screen: the color with its name.
struct ScreenLightView: View {
    @ObservedObject var flashlight: Flashlight

    var body: some View {
        GeometryReader { geo in
            ScreenLight(color: flashlight.color)
                .overlay(
                    Text(Flashlight.colors[flashlight.color].name)
                        .font(.system(size: geo.size.height * 0.09, weight: .bold))
                        .foregroundColor(.black.opacity(0.45))
                        .padding(.bottom, geo.size.height * 0.06),
                    alignment: .bottom)
        }
    }
}
