import SwiftUI

/// The menu bar remote: what the iPod is playing, transport buttons and its volume.
struct RemoteView: View {
    /// Opens the drag-and-drop window.
    let openMain: () -> Void
    @EnvironmentObject private var phone: Phone
    @State private var volume = 50.0
    @State private var draggingVolume = false
    @State private var lastVolumeSend = Date.distantPast
    @State private var sentVolume = -1
    @State private var startAtLogin = LoginItem.enabled

    var body: some View {
        VStack(spacing: 12) {
            if let status = phone.nowPlaying {
                VStack(spacing: 2) {
                    Text(status.title.isEmpty ? "Çalan şarkı yok" : status.title)
                        .font(.headline)
                    if !status.artist.isEmpty {
                        Text(status.artist).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                if status.duration > 0 {
                    VStack(spacing: 2) {
                        ProgressView(value: Double(status.elapsed), total: Double(status.duration))
                        HStack {
                            Text(time(status.elapsed))
                            Spacer()
                            Text("-" + time(status.duration - status.elapsed))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 28) {
                    button("backward.fill") { phone.command("prev") }
                    button(status.playing ? "pause.fill" : "play.fill", size: 26) { phone.command("toggle") }
                    button("forward.fill") { phone.command("next") }
                }

                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0 ... 100) { editing in
                        draggingVolume = editing
                        if !editing { sendVolume(force: true) }
                    }
                    .onChange(of: volume) { _ in
                        if draggingVolume { sendVolume(force: false) }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .onAppear { volume = Double(status.volume) }
                .onChange(of: status.volume) { new in
                    if !draggingVolume { volume = Double(new) }
                }
            } else if phone.name != nil {
                ProgressView().controlSize(.small)
            } else {
                Label("iPod bulunamadı", systemImage: "iphone.slash")
                Text("Telefonla aynı Wi-Fi'de olmalısın.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button(action: openMain) {
                Label("Şarkı Gönder…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            Toggle("Mac açılınca başlat", isOn: $startAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: startAtLogin) { LoginItem.enabled = $0 }
            HStack {
                Text(phone.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { phone.watching = true }
        .onDisappear { phone.watching = false }
    }

    /// Sends the volume while dragging, at most every 0.15 s so commands don't pile up; the final
    /// value always goes out on release.
    private func sendVolume(force: Bool) {
        let value = Int(volume)
        guard value != sentVolume, force || Date().timeIntervalSince(lastVolumeSend) > 0.15 else { return }
        sentVolume = value
        lastVolumeSend = Date()
        phone.command("vol \(value)")
    }

    private func button(_ symbol: String, size: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
        }
        .buttonStyle(.plain)
    }

    private func time(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(seconds, 0) / 60, max(seconds, 0) % 60)
    }
}
