import SwiftUI
import UniformTypeIdentifiers

struct Track: Identifiable {
    enum State {
        case searching
        case ready(Tagger.Info, guessed: Bool)
        case duplicate
        case adding
        case added
        case failed(String)
    }

    let id = UUID()
    let file: URL
    var state = State.searching

    var info: Tagger.Info? {
        if case .ready(let info, _) = state { return info }
        return nil
    }
}

struct ContentView: View {
    @State private var tracks: [Track] = []
    @State private var dropTargeted = false
    @State private var uploading = false

    private var readyCount: Int { tracks.filter { $0.info != nil }.count }
    private var searching: Bool { tracks.contains { if case .searching = $0.state { return true }; return false } }
    private var allDone: Bool {
        !tracks.isEmpty && tracks.allSatisfy {
            switch $0.state {
            case .added, .duplicate, .failed: return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty {
                emptyState
            } else {
                list
                Divider()
                footer
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, lineWidth: 3)
                .padding(4)
                .opacity(dropTargeted && !tracks.isEmpty ? 1 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { add(url) } }
                }
            }
            return true
        }
    }

    // MARK: Views

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("MP3'leri buraya sürükle")
                .font(.title2.weight(.semibold))
            Text("Şarkı adı, sanatçı, albüm ve kapak otomatik bulunur.")
                .foregroundStyle(.secondary)
            Button("Dosya Seç…", action: choose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(20)
        )
    }

    private var list: some View {
        List {
            ForEach(tracks) { track in
                TrackRow(track: track) { tracks.removeAll { $0.id == track.id } }
            }
            Text(allDone ? "Yeni şarkı eklemek için tekrar sürükleyebilirsin." : "Daha fazla şarkı sürükleyebilirsin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            if allDone {
                Label("Telefonu tak → Finder → iPhone → Müzik → Eşzamanla", systemImage: "iphone")
                    .font(.callout)
                Spacer()
                Button("Temizle") { tracks.removeAll() }
            } else {
                Button("Dosya Ekle…", action: choose)
                Spacer()
                if uploading || searching { ProgressView().controlSize(.small) }
                Button(uploading ? "Yükleniyor…" : "Yükle (\(readyCount))", action: upload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(readyCount == 0 || uploading)
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }

    private func add(_ url: URL) {
        if url.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            files.filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.path < $1.path }.forEach(add)
            return
        }
        guard url.pathExtension.lowercased() == "mp3", !tracks.contains(where: { $0.file == url }) else { return }
        let track = Track(file: url)
        tracks.append(track)
        Task {
            let state: Track.State
            do {
                let lookup = try await Tagger.lookup(url)
                state = isDuplicate(lookup.info) ? .duplicate : .ready(lookup.info, guessed: lookup.source != "itunes")
            } catch {
                state = .failed("Aranamadı")
            }
            update(track.id, state)
        }
    }

    /// Two downloads of the same song (e.g. a 320k and a normal one) are added only once.
    private func isDuplicate(_ info: Tagger.Info) -> Bool {
        let key = { (info: Tagger.Info) in "\(info.artistName)|\(info.trackName)".lowercased() }
        return tracks.contains { $0.info.map(key) == key(info) }
    }

    private func upload() {
        let items = tracks.compactMap { track in track.info.map { (track.id, track.file, $0) } }
        guard !items.isEmpty else { return }
        uploading = true
        items.forEach { update($0.0, .adding) }
        Task {
            let results = (try? await Tagger.apply(items.map { ($0.1, $0.2) })) ?? []
            for (id, file, _) in items {
                let result = results.first { $0.path == file.path }
                update(id, result?.ok == true ? .added : .failed(result?.error ?? "Eklenemedi"))
            }
            uploading = false
        }
    }

    private func update(_ id: UUID, _ state: Track.State) {
        if let index = tracks.firstIndex(where: { $0.id == id }) { tracks[index].state = state }
    }
}

private struct TrackRow: View {
    let track: Track
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(track.info?.trackName ?? track.file.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            status
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch track.state {
        case .searching: return "Aranıyor…"
        case .ready(let info, let guessed):
            return "\(info.artistName) · \(info.collectionName)" + (guessed ? "  (dosya adından tahmin)" : "")
        case .duplicate: return "Aynı şarkı zaten listede"
        case .adding: return "Ekleniyor…"
        case .added: return "Müzik uygulamasına eklendi"
        case .failed(let message): return message
        }
    }

    private var cover: some View {
        Group {
            if let url = track.info?.artworkURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var status: some View {
        switch track.state {
        case .searching, .adding:
            ProgressView().controlSize(.small)
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready, .duplicate:
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Listeden çıkar")
        }
    }
}
