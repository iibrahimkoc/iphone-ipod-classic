import SwiftUI
import MediaPlayer

struct ContentView: View {
    @StateObject private var model = IPodModel()

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width - 32
            let screenHeight = screenWidth * 0.75
            let wheelSize = min(geo.size.width * 0.82, geo.size.height - screenHeight - 72)

            VStack(spacing: 0) {
                ScreenView(model: model, player: model.player, volume: model.volume,
                           bluetooth: model.bluetooth, wifi: model.wifi, route: model.route, airplane: model.airplane)
                    .frame(width: screenWidth, height: screenHeight)
                    .padding(.top, 24)
                Spacer(minLength: 0)
                ClickWheel(
                    onScroll: model.scroll,
                    onSelect: model.select,
                    onMenu: model.menu,
                    onPlayPause: model.player.togglePlay,
                    onNext: model.player.next,
                    onPrevious: model.player.previous)
                    .frame(width: wheelSize, height: wheelSize)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.03)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        .background(VolumeViewHost(view: model.volume.view).frame(width: 1, height: 1).opacity(0.01))
        .statusBarHidden(true)
        .onAppear { model.requestAccess() }
    }
}

private struct VolumeViewHost: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Screen

private let highlight = LinearGradient(
    colors: [Color(red: 0.45, green: 0.68, blue: 0.96), Color(red: 0.12, green: 0.40, blue: 0.86)],
    startPoint: .top, endPoint: .bottom)

struct ScreenView: View {
    @ObservedObject var model: IPodModel
    @ObservedObject var player: PlayerController
    @ObservedObject var volume: VolumeController
    @ObservedObject var bluetooth: BluetoothController
    @ObservedObject var wifi: WiFiController
    @ObservedObject var route: AudioRouteController
    @ObservedObject var airplane: AirplaneController

    @State private var swipeAxis: Axis?
    @State private var lastTranslation = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            let barHeight = geo.size.height * 0.12
            let rowHeight = (geo.size.height - barHeight) / CGFloat(IPodModel.visibleRows)

            VStack(spacing: 0) {
                // While volume or brightness is being changed, its level takes over the title bar.
                Group {
                    if let hud = model.hud {
                        hudBar(hud, height: barHeight)
                    } else {
                        TitleBar(title: model.title, isPlaying: player.isPlaying, hasItem: player.item != nil,
                                 output: route.output)
                    }
                }
                .frame(height: barHeight)
                Group {
                    if !model.authorized {
                        Text("Müzik erişimi yok.\nAyarlar › iPod › Medya ve Apple Music")
                            .font(.system(size: rowHeight * 0.4))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                            .padding(.top, rowHeight)
                    } else {
                        switch model.current {
                        case .list(let list):
                            ListView(screen: list, rowHeight: rowHeight)
                        case .live:
                            if let list = model.currentList {
                                ListView(screen: list, rowHeight: rowHeight)
                            }
                        case .password(let entry):
                            PasswordView(entry: entry)
                        case .nowPlaying:
                            NowPlayingView(player: player)
                        case .clickVolume:
                            ClickVolumeView(level: model.clickVolume)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .contentShape(Rectangle())
            .gesture(swipe(size: geo.size))
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black, lineWidth: 2))
    }

    /// Horizontal swipes change brightness, vertical swipes change volume (up is louder).
    /// The axis is locked at the start of each swipe so diagonal drags don't change both.
    private func swipe(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let t = value.translation
                let axis = swipeAxis ?? (abs(t.width) > abs(t.height) ? .horizontal : .vertical)
                swipeAxis = axis
                if axis == .horizontal {
                    model.adjustBrightness(by: Double((t.width - lastTranslation.width) / size.width))
                } else {
                    model.adjustVolume(by: Double((lastTranslation.height - t.height) / size.height))
                }
                lastTranslation = t
            }
            .onEnded { _ in
                swipeAxis = nil
                lastTranslation = .zero
            }
    }

    private func hudBar(_ hud: HUD, height: CGFloat) -> some View {
        let level = min(max(hud == .volume ? Double(volume.level) : model.brightness, 0), 1)
        return HStack(spacing: 6) {
            Image(systemName: hud == .volume ? "speaker.wave.2.fill" : "sun.max.fill")
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.88))
                    Rectangle().fill(highlight).frame(width: bar.size.width * CGFloat(level))
                }
                .overlay(Rectangle().stroke(Color(white: 0.55), lineWidth: 0.5))
            }
            .frame(height: height * 0.3)
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: height * 0.36, weight: .medium))
                .foregroundColor(Color(white: 0.3))
                .frame(width: height * 1.3, alignment: .trailing)
        }
        .font(.system(size: height * 0.45, weight: .semibold))
        .foregroundColor(.black)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.80)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(Color(white: 0.55)).frame(height: 1), alignment: .bottom)
    }
}

struct TitleBar: View {
    let title: String
    let isPlaying: Bool
    let hasItem: Bool
    let output: AudioRouteController.Output

    var body: some View {
        GeometryReader { geo in
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .opacity(hasItem ? 1 : 0)
                    Image(systemName: output.symbol)
                        .font(.system(size: geo.size.height * 0.42))
                }
                Spacer()
                HStack(spacing: 3) {
                    if let percent = batteryPercent {
                        Text("\(percent)%")
                            .font(.system(size: geo.size.height * 0.36, weight: .medium))
                            .foregroundColor(Color(white: 0.3))
                    }
                    Image(systemName: batterySymbol)
                }
            }
            // Overlaid so the title stays centered even though the side items differ in width.
            .overlay(Text(title).lineLimit(1).padding(.horizontal, geo.size.height * 2.2))
            .font(.system(size: geo.size.height * 0.5, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .background(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.80)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(Color(white: 0.55)).frame(height: 1), alignment: .bottom)
    }

    private var batteryPercent: Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    private var batterySymbol: String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        if device.batteryState == .charging || device.batteryState == .full { return "battery.100.bolt" }
        switch device.batteryLevel {
        case ..<0: return "battery.100"
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct ListView: View {
    let screen: ListScreen
    let rowHeight: CGFloat

    var body: some View {
        if screen.items.isEmpty {
            Text("Boş")
                .font(.system(size: rowHeight * 0.5))
                .foregroundColor(.gray)
                .padding(.top, rowHeight)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    let end = min(screen.top + IPodModel.visibleRows, screen.items.count)
                    ForEach(screen.top ..< end, id: \.self) { index in
                        row(screen.items[index], selected: index == screen.selection)
                    }
                }
                if screen.items.count > IPodModel.visibleRows {
                    scrollBar
                }
            }
        }
    }

    private func row(_ item: MenuItem, selected: Bool) -> some View {
        HStack {
            Text(item.title).lineLimit(1)
            Spacer(minLength: 4)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: rowHeight * 0.42, weight: .medium))
                    .foregroundColor(selected ? .white : Color(white: 0.45))
            }
            if item.showsChevron {
                Image(systemName: "chevron.right")
            }
        }
        .font(.system(size: rowHeight * 0.52, weight: .semibold))
        .foregroundColor(selected ? .white : .black)
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(Group { if selected { highlight } })
    }

    private var scrollBar: some View {
        GeometryReader { geo in
            let total = CGFloat(screen.items.count)
            let height = geo.size.height * CGFloat(IPodModel.visibleRows) / total
            let offset = geo.size.height * CGFloat(screen.top) / total
            ZStack(alignment: .top) {
                Rectangle().fill(Color(white: 0.9))
                Rectangle().fill(highlight).frame(height: height).offset(y: offset)
            }
            .overlay(Rectangle().stroke(Color(white: 0.6), lineWidth: 0.5))
        }
        .frame(width: 8, height: rowHeight * CGFloat(IPodModel.visibleRows))
    }
}

struct NowPlayingView: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            if let item = player.item {
                VStack(alignment: .leading, spacing: h * 0.04) {
                    Text(player.queueCount > 0 ? "\(player.queueIndex + 1) / \(player.queueCount)" : " ")
                        .font(.system(size: h * 0.07, weight: .semibold))
                    HStack(alignment: .top, spacing: 10) {
                        artwork(item, size: h * 0.5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title ?? "Bilinmeyen")
                                .font(.system(size: h * 0.08, weight: .bold))
                            Text(item.artist ?? "")
                                .font(.system(size: h * 0.07))
                            Text(item.albumTitle ?? "")
                                .font(.system(size: h * 0.07))
                                .foregroundColor(.gray)
                        }
                        .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        bar(player.duration > 0 ? player.elapsed / player.duration : 0)
                        HStack {
                            Text(format(player.elapsed))
                            Spacer()
                            Text("-" + format(max(player.duration - player.elapsed, 0)))
                        }
                        .font(.system(size: h * 0.06, weight: .semibold))
                    }
                    .frame(height: h * 0.1)
                }
                .foregroundColor(.black)
                .padding(10)
            } else {
                Text("Çalan şarkı yok")
                    .font(.system(size: h * 0.08))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func artwork(_ item: MPMediaItem, size: CGFloat) -> some View {
        Group {
            if let image = item.artwork?.image(at: CGSize(width: size * 2, height: size * 2)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.85)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(Color(white: 0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .shadow(radius: 1)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.88))
                Rectangle().fill(highlight)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
            .overlay(Rectangle().stroke(Color(white: 0.55), lineWidth: 0.5))
        }
        .frame(height: 8)
    }

    private func format(_ time: TimeInterval) -> String {
        let seconds = Int(time)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct ClickVolumeView: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: h * 0.08) {
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: h * 0.22, weight: .bold))
                GeometryReader { bar in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(white: 0.88))
                        Rectangle().fill(highlight).frame(width: bar.size.width * CGFloat(level))
                    }
                    .overlay(Rectangle().stroke(Color(white: 0.55), lineWidth: 0.5))
                }
                .frame(height: 10)
                Text("Çarkı çevirerek ayarla")
                    .font(.system(size: h * 0.07))
                    .foregroundColor(.gray)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PasswordView: View {
    let entry: PasswordEntry

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: h * 0.06) {
                Text(entry.network.ssid)
                    .font(.system(size: h * 0.07, weight: .semibold))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                Text(entry.text.isEmpty ? " " : entry.text)
                    .font(.system(size: h * 0.09, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: h * 0.14)
                    .overlay(Rectangle().stroke(Color(white: 0.6), lineWidth: 1))
                // A strip of options centered on the current one, like a dial.
                HStack(spacing: 0) {
                    ForEach(-3 ... 3, id: \.self) { offset in
                        let options = PasswordEntry.options
                        let option = options[((entry.index + offset) % options.count + options.count) % options.count]
                        Text(option == " " ? "␣" : option)
                            .font(.system(size: h * (offset == 0 ? 0.11 : 0.08), weight: offset == 0 ? .bold : .regular))
                            .foregroundColor(offset == 0 ? .white : Color(white: 0.4))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: offset == 0 ? h * 0.42 : (geo.size.width - h * 0.42 - 20) / 6, height: h * 0.16)
                            .background(Group { if offset == 0 { highlight } })
                    }
                }
                Text("Çevir: seç · Orta: ekle · MENU: iptal")
                    .font(.system(size: h * 0.055))
                    .foregroundColor(.gray)
            }
            .foregroundColor(.black)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
