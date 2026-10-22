import SwiftUI
import UniformTypeIdentifiers

struct Track: Identifiable {
    enum State {
        case searching
        case ready(Tagger.Info, guessed: Bool)
        case duplicate
        case adding
        case added
        case sent
        /// With the tags it was going to get, when sending can be tried again.
        case failed(String, retry: Tagger.Info? = nil)
    }

    let id = UUID()
    let file: URL
    var state = State.searching

    var info: Tagger.Info? {
        if case .ready(let info, _) = state { return info }
        return nil
    }

    var retryInfo: Tagger.Info? {
        if case .failed(_, let info) = state { return info }
        return nil
    }
}

/// A game file waiting to go to one of the iPod's Oyunlar folders.
struct GameItem: Identifiable {
    enum State {
        case ready, sending, sent
        case failed(String)
    }

    let id = UUID()
    let file: URL
    /// The folder on the phone, e.g. /var/mobile/Media/iPodOyun/NES.
    let folder: String
    var state = State.ready

    var console: String {
        switch (folder as NSString).lastPathComponent {
        case "MegaDrive": return "Mega Drive"
        case let name: return name
        }
    }

    /// Still to be sent (again, if it failed).
    var pending: Bool {
        switch state {
        case .ready, .failed: return true
        case .sending, .sent: return false
        }
    }
}

struct ContentView: View {
    let openLibrary: () -> Void
    @EnvironmentObject private var phone: Phone
    @State private var tracks: [Track] = []
    @State private var dropTargeted = false
    @State private var uploading = false
    @State private var askingAddress = false
    /// "Tek albüm yap": everything in the list becomes one album, in list order.
    @State private var singleAlbum = false
    @State private var albumName = "Piyano"
    @State private var address = ""
    @State private var games: [GameItem] = []

    private var readyCount: Int { tracks.filter { $0.info != nil || $0.retryInfo != nil }.count }
    private var pendingGames: Int { games.filter(\.pending).count }
    private var songsPending: Bool { tracks.contains { $0.info != nil || $0.retryInfo != nil } || searching }
    private var searching: Bool { tracks.contains { if case .searching = $0.state { return true }; return false } }
    private var allDone: Bool {
        (!tracks.isEmpty || !games.isEmpty) && games.allSatisfy { if case .sent = $0.state { return true }; return false }
            && tracks.allSatisfy {
            switch $0.state {
            case .failed(_, let retry): return retry == nil
            case .added, .sent, .duplicate: return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tracks.isEmpty && games.isEmpty {
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
                .opacity(dropTargeted && !(tracks.isEmpty && games.isEmpty) ? 1 : 0)
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
            Text("Oyunlar da olur: .nes, .md, .wad dosyaları iPod'un Oyunlar bölümüne gider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Dosya Seç…", action: choose)
            Button("iPod'daki şarkıları düzenle…", action: openLibrary)
                .buttonStyle(.link)
                .padding(.top, 8)
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
            ForEach(games) { game in
                GameRow(game: game) { games.removeAll { $0.id == game.id } }
            }
            Text(allDone ? "Yeni şarkı ya da oyun eklemek için tekrar sürükleyebilirsin." : "Daha fazla şarkı ya da oyun sürükleyebilirsin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !allDone && songsPending {
                HStack {
                    Toggle("Tek albüm yap:", isOn: $singleAlbum)
                    TextField("Albüm adı", text: $albumName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .disabled(!singleAlbum)
                }
                .font(.callout)
            }
            footerButtons
        }
        .padding(12)
    }

    private var footerButtons: some View {
        HStack {
            phoneStatus
            Spacer()
            if allDone {
                Button("Temizle") {
                    tracks.removeAll()
                    games.removeAll()
                }
            } else {
                if uploading || searching { ProgressView().controlSize(.small) }
                Menu("Mac'e Ekle") {
                    Button("Mac'teki Müzik uygulamasına ekle (Finder ile eşitlemek için)", action: upload)
                }
                .fixedSize()
                .disabled(readyCount == 0 || uploading)
                Button(uploading ? "Gönderiliyor…" : "iPod'a Gönder (\(readyCount + pendingGames))", action: sendToPhone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(readyCount + pendingGames == 0 || uploading || !phone.found)
            }
        }
    }

    /// The tracks to tag, with the album overridden when "Tek albüm yap" is on.
    private func itemsToTag() -> [(UUID, URL, Tagger.Info)] {
        let items = tracks.compactMap { track in track.info.map { (track.id, track.file, $0) } }
        // Failed sends keep the tags they were given (album, track number), so they go as they were.
        let retries = tracks.compactMap { track in track.retryInfo.map { (track.id, track.file, $0) } }
        let name = albumName.trimmingCharacters(in: .whitespaces)
        guard singleAlbum, !name.isEmpty else { return retries + items }
        return retries + items.enumerated().map { index, item in
            var info = item.2
            info.collectionName = name
            info.albumArtist = "Çeşitli Sanatçılar"
            info.trackNumber = index + 1
            info.trackCount = items.count
            info.artworkUrl100 = items.first?.2.artworkUrl100 ?? info.artworkUrl100
            return (item.0, item.1, info)
        }
    }

    private var phoneStatus: some View {
        Group {
            if let name = phone.name {
                Label(name, systemImage: "iphone")
            } else {
                HStack(spacing: 6) {
                    Label("iPod aranıyor… (aynı Wi-Fi'de olmalı)", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                    Button("Adres gir…") { askingAddress = true }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .lineLimit(1)
        .alert("iPod'un adresi", isPresented: $askingAddress) {
            TextField("192.168.1.164", text: $address)
            Button("Bağlan") { phone.add(address: address) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("iPod'da Ayarlar → Wi-Fi → IP Adresi satırında yazıyor.")
        }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3] + Phone.gameFolders.keys.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { panel.urls.forEach(add) }
    }

    private func add(_ url: URL) {
        if let folder = Phone.gameFolder(for: url) {
            if !games.contains(where: { $0.file == url }) { games.append(GameItem(file: url, folder: folder)) }
            return
        }
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
                state = isDuplicate(lookup.info) ? .duplicate : .ready(lookup.info, guessed: lookup.source == "guess")
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
        let items = itemsToTag()
        guard !items.isEmpty else { return }
        uploading = true
        items.forEach { update($0.0, .adding) }
        Task {
            let results = (try? await Tagger.apply(items.map { ($0.1, $0.2) })) ?? []
            for (id, file, info) in items {
                let result = results.first { $0.path == file.path }
                update(id, result?.ok == true ? .added : .failed(result?.error ?? "Eklenemedi", retry: info))
            }
            uploading = false
        }
    }

    /// Tags the files, then copies them straight into the iPod's music folder over Wi-Fi; games go
    /// into their console's folder as they are.
    private func sendToPhone() {
        let items = itemsToTag()
        let gameIDs = games.filter(\.pending).map(\.id)
        guard !items.isEmpty || !gameIDs.isEmpty else { return }
        uploading = true
        items.forEach { update($0.0, .adding) }
        Task {
            for id in gameIDs {
                guard let game = games.first(where: { $0.id == id }) else { continue }
                setGame(id, .sending)
                do {
                    try await phone.send(game.file, as: game.file.lastPathComponent, to: game.folder)
                    setGame(id, .sent)
                } catch {
                    setGame(id, .failed("Gönderilemedi (iPod açık ve aynı Wi-Fi'de mi?)"))
                }
            }
            let tagged = items.isEmpty ? [] : (try? await Tagger.tagOnly(items.map { ($0.1, $0.2) })) ?? []
            for (id, file, info) in items {
                guard tagged.first(where: { $0.path == file.path })?.ok == true else {
                    update(id, .failed("Etiketlenemedi", retry: info))
                    continue
                }
                do {
                    try await phone.send(file, as: fileName(info, ext: file.pathExtension))
                    update(id, .sent)
                } catch {
                    update(id, .failed("Gönderilemedi (iPod açık ve aynı Wi-Fi'de mi?)", retry: info))
                }
            }
            uploading = false
        }
    }

    private func setGame(_ id: UUID, _ state: GameItem.State) {
        if let index = games.firstIndex(where: { $0.id == id }) { games[index].state = state }
    }

    /// "Sertab Erener - Yanarım.mp3", with characters that can't be in a file name removed.
    private func fileName(_ info: Tagger.Info, ext: String) -> String {
        let base = "\(info.artistName) - \(info.trackName)"
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: " ")
        return "\(base).\(ext.lowercased())"
    }

    private func update(_ id: UUID, _ state: Track.State) {
        if let index = tracks.firstIndex(where: { $0.id == id }) { tracks[index].state = state }
    }
}

private struct GameRow: View {
    let game: GameItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.secondary.opacity(0.2)
                Image(systemName: "gamecontroller").foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.file.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            switch game.state {
            case .sending:
                ProgressView().controlSize(.small)
            case .sent:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .ready:
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Listeden çıkar")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch game.state {
        case .ready: return "Oyun · Oyunlar › \(game.console)"
        case .sending: return "Gönderiliyor…"
        case .sent: return "iPod'a gönderildi · Oyunlar › \(game.console)"
        case .failed(let message): return message + " · tekrar denemek için iPod'a Gönder"
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text((track.info ?? track.retryInfo)?.trackName ?? track.file.deletingPathExtension().lastPathComponent)
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
        case .added: return "Mac'teki Müzik uygulamasına eklendi"
        case .sent: return "iPod'a gönderildi"
        case .failed(let message, let retry): return message + (retry == nil ? "" : " · tekrar denemek için iPod'a Gönder")
        }
    }

    private var cover: some View {
        Group {
            if let url = (track.info ?? track.retryInfo)?.artworkURL {
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
        case .added, .sent:
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
