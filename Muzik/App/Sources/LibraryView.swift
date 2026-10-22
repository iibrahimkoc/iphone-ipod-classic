import SwiftUI

/// The songs already in the iPod's music folder, to fix their order, names, albums and covers on
/// the Mac. Nothing changes on the phone until "Kaydet", which rewrites only the changed songs'
/// tags there (the audio isn't sent again).
struct LibraryView: View {
    struct Album: Identifiable {
        /// The album name in lowercase, as the iPod groups it ("" for songs without an album).
        let id: String
        let name: String
        let songs: [Tagger.PhoneSong]
    }

    @EnvironmentObject private var phone: Phone
    @State private var original: [Tagger.PhoneSong] = []
    @State private var songs: [Tagger.PhoneSong] = []
    @State private var deleted: [String] = []
    @State private var ratings: [String: Phone.Rating] = [:]
    @State private var selection: String?
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    /// The songs waiting for a typed album name ("Yeni albüm…" or renaming an album).
    @State private var naming: [String]?
    @State private var draft = ""

    private var albums: [Album] {
        Dictionary(grouping: songs, by: { $0.album.lowercased() })
            .map { key, songs in
                Album(id: key, name: songs[0].album.isEmpty ? "Albümsüz" : songs[0].album,
                      songs: songs.sorted { ($0.track, $0.title) < ($1.track, $1.title) })
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var changed: [Tagger.PhoneSong] {
        songs.filter { song in original.first { $0.name == song.name } != song }
    }

    private var changeCount: Int { changed.count + deleted.count }

    var body: some View {
        VStack(spacing: 0) {
            if songs.isEmpty {
                emptyState
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            bottomBar
        }
        .onAppear { if songs.isEmpty { load() } }
        // The window can open before the iPod is found.
        .onChange(of: phone.found) { found in if found && songs.isEmpty && !loading { load() } }
        .alert("Albüm adı", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Albüm adı", text: $draft)
            Button("Tamam") {
                let name = draft.trimmingCharacters(in: .whitespaces)
                if let names = naming, !name.isEmpty { move(names, toAlbum: name) }
                naming = nil
            }
            Button("Vazgeç", role: .cancel) { naming = nil }
        } message: {
            Text("Var olan bir albümün adını yazarsan şarkılar o albümün sonuna eklenir.")
        }
    }

    // MARK: Views

    private var emptyState: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                Text("iPod'daki şarkılar okunuyor…").foregroundStyle(.secondary)
            } else if !phone.found {
                Image(systemName: "iphone.slash").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text("iPod bulunamadı (aynı Wi-Fi'de olmalı)").foregroundStyle(.secondary)
            } else {
                Text(message ?? "iPod'da Wi-Fi ile gönderilmiş şarkı yok.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The sidebar entry of the disliked songs; album ids are lowercase names, so it can't clash.
    private static let dislikedTag = "#beğenilmeyenler"

    /// Disliked on the iPod, minus the songs already deleted. A song in the folder is
    /// "file:<file name>"; a Finder-synced one has only its title and artist.
    private var disliked: [(id: String, rating: Phone.Rating, song: Tagger.PhoneSong?)] {
        ratings.filter(\.value.disliked).compactMap { id, rating in
            guard id.hasPrefix("file:") else { return (id, rating, nil) }
            let name = String(id.dropFirst(5))
            guard let song = songs.first(where: { $0.name == name }) else { return nil }
            return (id, rating, song)
        }
        .sorted { $0.rating.title.localizedCompare($1.rating.title) == .orderedAscending }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !disliked.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Beğenmediklerim").lineLimit(1)
                        Text("\(disliked.count) şarkı").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(Self.dislikedTag)
            }
            ForEach(albums) { album in
                HStack(spacing: 10) {
                    CoverImage(path: album.songs[0].cover, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(album.name).lineLimit(1)
                        Text("\(album.songs.count) şarkı").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .tag(album.id)
            }
        }
    }

    private var dislikedDetail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Beğenmediklerim").font(.title2.weight(.semibold))
                    Text("iPod'da beğenmediğin şarkılar. Karıştırırken çalınmazlar; silersen iPod'dan tamamen çıkarlar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Hepsini iPod'dan sil") { disliked.compactMap(\.song).forEach(delete) }
                    .disabled(!disliked.contains { $0.song != nil })
            }
            .padding(14)
            Divider()
            List(disliked, id: \.id) { entry in
                HStack(spacing: 10) {
                    CoverImage(path: entry.song?.cover, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.song?.title ?? entry.rating.title).lineLimit(1)
                        Text(entry.song?.artist ?? entry.rating.artist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let song = entry.song {
                        Button("iPod'dan sil", role: .destructive) { delete(song) }
                    } else {
                        Text("Finder ile eşitlendi, Müzik'ten kaldır")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if selection == Self.dislikedTag {
            dislikedDetail
        } else if let album = albums.first(where: { $0.id == selection }) {
            VStack(spacing: 0) {
                header(album)
                Divider()
                List {
                    ForEach(album.songs) { song in row(song, in: album) }
                        .onMove { reorder(album, from: $0, to: $1) }
                }
            }
        } else {
            Text("Soldan bir albüm seç.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ album: Album) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                // The iPod shows the first song's cover as the album's.
                CoverImage(path: album.songs[0].cover, size: 84)
                Menu("Kapak") {
                    ForEach(album.songs.filter { $0.cover != nil }) { song in
                        Button("\(song.title) kapağı") { setCover(song.cover, for: album) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Seçilen kapak albümdeki tüm şarkılara konur")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(album.name).font(.title2.weight(.semibold)).lineLimit(1)
                    Button("Yeniden adlandır…") {
                        draft = album.id.isEmpty ? "" : album.name
                        naming = album.songs.map(\.name)
                    }
                    .buttonStyle(.link)
                }
                TextField("Albüm sanatçısı", text: albumArtist(album))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Text("Sırayı değiştirmek için şarkıları sürükle. Ad ve sanatçıya tıklayıp düzeltebilirsin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ song: Tagger.PhoneSong, in album: Album) -> some View {
        HStack(spacing: 10) {
            Text("\(song.track)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            CoverImage(path: song.cover, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Şarkı adı", text: field(song.name, \.title)).textFieldStyle(.plain)
                TextField("Sanatçı", text: field(song.name, \.artist))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if original.first(where: { $0.name == song.name }) != song {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Kaydedilmedi")
            }
            Menu {
                Menu("Albüme taşı") {
                    Button("Yeni albüm…") {
                        draft = ""
                        naming = [song.name]
                    }
                    Divider()
                    ForEach(albums.filter { $0.id != album.id && !$0.id.isEmpty }) { other in
                        Button(other.name) { move([song.name], toAlbum: other.name) }
                    }
                }
                Button("Bu kapağı tüm albüme koy") { setCover(song.cover, for: album) }
                    .disabled(song.cover == nil)
                Divider()
                Button("iPod'dan sil", role: .destructive) { delete(song) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var bottomBar: some View {
        HStack {
            if loading || saving { ProgressView().controlSize(.small) }
            Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Yenile") { load() }
                .disabled(loading || saving || !phone.found)
                .help(changeCount > 0 ? "Kaydedilmemiş değişiklikler silinir" : "iPod'dan tekrar oku")
            Button(changeCount > 0 ? "Kaydet (\(changeCount))" : "Kaydet", action: save)
                .keyboardShortcut("s")
                .disabled(changeCount == 0 || saving || !phone.found)
        }
        .padding(12)
    }

    private var status: String {
        if saving { return "iPod'a kaydediliyor…" }
        var parts: [String] = []
        if !changed.isEmpty { parts.append("\(changed.count) şarkı değişti") }
        if !deleted.isEmpty { parts.append("\(deleted.count) şarkı silinecek") }
        return parts.isEmpty ? (message ?? "\(songs.count) şarkı") : parts.joined(separator: ", ")
    }

    // MARK: Editing

    private func field(_ name: String, _ key: WritableKeyPath<Tagger.PhoneSong, String>) -> Binding<String> {
        Binding(
            get: { songs.first { $0.name == name }?[keyPath: key] ?? "" },
            set: { value in
                if let index = songs.firstIndex(where: { $0.name == name }) { songs[index][keyPath: key] = value }
            })
    }

    private func albumArtist(_ album: Album) -> Binding<String> {
        Binding(
            get: { album.songs[0].albumArtist },
            set: { value in
                for index in songs.indices where songs[index].album.lowercased() == album.id {
                    songs[index].albumArtist = value
                }
            })
    }

    private func reorder(_ album: Album, from source: IndexSet, to destination: Int) {
        var names = album.songs.map(\.name)
        names.move(fromOffsets: source, toOffset: destination)
        number(names)
    }

    /// Numbers the songs 1, 2, 3… in the given order.
    private func number(_ names: [String]) {
        for (position, name) in names.enumerated() {
            if let index = songs.firstIndex(where: { $0.name == name }) { songs[index].track = position + 1 }
        }
    }

    /// Puts the songs at the end of the album `name` (made if new), taking its album artist.
    private func move(_ names: [String], toAlbum name: String) {
        let leaving = Set(albums.filter { album in album.songs.contains { names.contains($0.name) } }.map(\.id))
        let target = albums.first { $0.id == name.lowercased() }
        let staying = target?.songs.filter { !names.contains($0.name) } ?? []
        let artist = staying.first?.albumArtist
        for index in songs.indices where names.contains(songs[index].name) {
            songs[index].album = staying.first?.album ?? name
            if let artist = artist { songs[index].albumArtist = artist }
        }
        number(staying.map(\.name) + names)
        for album in albums where leaving.contains(album.id) && album.id != name.lowercased() {
            number(album.songs.map(\.name))
        }
        selection = name.lowercased()
    }

    private func setCover(_ cover: String?, for album: Album) {
        guard let cover = cover else { return }
        for index in songs.indices where songs[index].album.lowercased() == album.id { songs[index].cover = cover }
    }

    private func delete(_ song: Tagger.PhoneSong) {
        songs.removeAll { $0.name == song.name }
        deleted.append(song.name)
        if let album = albums.first(where: { $0.id == song.album.lowercased() }) { number(album.songs.map(\.name)) }
    }

    // MARK: Phone

    /// Reads the iPod's songs again, dropping unsaved changes; `note` is shown once read.
    private func load(then note: String? = nil) {
        guard let target = phone.target else { return }
        loading = true
        Task {
            do {
                let read = try await Tagger.phoneSongs(host: target.host, folder: target.folder)
                ratings = await phone.ratings()
                original = read
                songs = read
                deleted = []
                message = note
                if selection != Self.dislikedTag || disliked.isEmpty,
                   !albums.contains(where: { $0.id == selection }) {
                    selection = disliked.isEmpty ? albums.first?.id : Self.dislikedTag
                }
            } catch {
                message = "iPod'daki şarkılar okunamadı."
            }
            loading = false
        }
    }

    private func save() {
        guard let target = phone.target else { return }
        let counts = Dictionary(grouping: songs, by: { $0.album.lowercased() }).mapValues(\.count)
        let edits = changed.map { song in
            Tagger.PhoneEdit(song: song, trackCount: counts[song.album.lowercased()] ?? 0,
                             newCover: original.first { $0.name == song.name }?.cover != song.cover)
        }
        saving = true
        Task {
            let results = (try? await Tagger.saveToPhone(host: target.host, folder: target.folder,
                                                         edits: edits, delete: deleted)) ?? []
            let failed = edits.count + deleted.count - results.filter(\.ok).count
            saving = false
            load(then: failed == 0 ? "Kaydedildi." : "\(failed) şarkı kaydedilemedi.")
        }
    }
}

/// A cover from muzik.py's cache folder, or a placeholder.
private struct CoverImage: View {
    let path: String?
    let size: CGFloat
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }

    private var image: NSImage? {
        guard let path = path else { return nil }
        if let cached = Self.cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        Self.cache.setObject(image, forKey: path as NSString)
        return image
    }
}
