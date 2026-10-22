import UIKit
import MediaPlayer
import AVFoundation

/// A song from either the iOS music library (synced from Finder) or the app's own folder
/// (sent from the Mac over Wi-Fi).
final class Song: Identifiable {
    let id: String
    let url: URL
    let title: String
    let artist: String?
    let albumArtist: String?
    let album: String?
    let trackNumber: Int
    let duration: TimeInterval
    private let loadArtwork: (CGSize) -> UIImage?

    init(id: String, url: URL, title: String, artist: String?, albumArtist: String?, album: String?,
         trackNumber: Int, duration: TimeInterval, artwork: @escaping (CGSize) -> UIImage?) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = Self.nonEmpty(artist)
        self.albumArtist = Self.nonEmpty(albumArtist)
        self.album = Self.nonEmpty(album)
        self.trackNumber = trackNumber
        self.duration = duration
        loadArtwork = artwork
    }

    /// Like the original iPod, untagged songs go under "Bilinmeyen …".
    var artistName: String { albumArtist ?? artist ?? "Bilinmeyen Sanatçı" }
    var albumName: String { album ?? "Bilinmeyen Albüm" }

    func artwork(size: CGFloat) -> UIImage? {
        loadArtwork(CGSize(width: size, height: size))
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

struct Album: Identifiable {
    let id: String
    let songs: [Song]

    var name: String { songs[0].albumName }
    var artistName: String { songs[0].artistName }
}

/// All playable songs: the iOS music library plus the files in `folder`, which the Mac's
/// iPod Müzik app fills over SSH. The folder is polled, so new songs show up on their own.
final class SongLibrary: ObservableObject {
    static let folder = URL(fileURLWithPath: "/var/mobile/Media/iPodMuzik")
    private static let fileTypes: Set<String> = ["mp3", "m4a", "aac", "wav"]

    @Published private(set) var songs: [Song] = []
    /// True while the Mac is copying files in (they arrive as hidden ".*.part" files).
    @Published private(set) var receiving = false

    private var fileSongs: [String: (date: Date, song: Song)] = [:]
    private var folderState = ""
    private var timer: Timer?
    private let service = NetService(domain: "local.", type: "_ipodmuzik._tcp.", name: UIDevice.current.name, port: 22)

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkFolder() }
        // Lets the Mac find the phone by name on the same Wi-Fi.
        service.setTXTRecord(NetService.data(fromTXTRecord: ["folder": Data(Self.folder.path.utf8)]))
        service.publish()
    }

    func reload() {
        let library = (MPMediaQuery.songs().items ?? [])
            .filter { $0.assetURL != nil && !$0.hasProtectedAsset }
            .map(Self.song(from:))
        songs = (library + loadFolder()).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    /// Finder-synced songs inside an MPMediaPlaylist, as Songs.
    func songs(in playlist: MPMediaPlaylist) -> [Song] {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.items.compactMap { byID["lib:\($0.persistentID)"] }
    }

    // MARK: Grouping

    func albums(of songs: [Song]) -> [Album] {
        group(songs, key: { song in song.album.map { "\(song.artistName.lowercased())|\($0.lowercased())" } },
              name: { $0.albumName })
            .map { Album(id: $0.key, songs: $0.songs.sorted { $0.trackNumber < $1.trackNumber }) }
    }

    func artists(of songs: [Song]) -> [(name: String, songs: [Song])] {
        group(songs, key: { ($0.albumArtist ?? $0.artist)?.lowercased() }, name: { $0.artistName })
            .map { ($0.songs[0].artistName, $0.songs) }
    }

    /// Groups songs by `key` (nil = unknown), sorted by name with the unknown group last.
    private func group(_ songs: [Song], key: (Song) -> String?, name: (Song) -> String) -> [(key: String, songs: [Song])] {
        var groups: [String: [Song]] = [:]
        var unknown: [Song] = []
        for song in songs {
            if let key = key(song) {
                groups[key, default: []].append(song)
            } else {
                unknown.append(song)
            }
        }
        var result = groups.map { (key: $0.key, songs: $0.value) }
            .sorted { name($0.songs[0]).localizedCompare(name($1.songs[0])) == .orderedAscending }
        if !unknown.isEmpty { result.append((key: "unknown", songs: unknown)) }
        return result
    }

    // MARK: Folder

    private func folderEntries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [])) ?? []
    }

    private func checkFolder() {
        let entries = folderEntries()
        receiving = entries.contains { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "part" }
        let state = entries.map { "\($0.lastPathComponent)|\(modified($0).timeIntervalSince1970)" }.sorted().joined(separator: "\n")
        if state != folderState {
            folderState = state
            reload()
        }
    }

    private func loadFolder() -> [Song] {
        var loaded: [String: (date: Date, song: Song)] = [:]
        for url in folderEntries() where !url.lastPathComponent.hasPrefix(".")
            && Self.fileTypes.contains(url.pathExtension.lowercased()) {
            let date = modified(url)
            if let cached = fileSongs[url.lastPathComponent], cached.date == date {
                loaded[url.lastPathComponent] = cached
            } else {
                loaded[url.lastPathComponent] = (date, Self.song(fromFile: url))
            }
        }
        fileSongs = loaded
        return loaded.values.map(\.song)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Song sources

    private static func song(from item: MPMediaItem) -> Song {
        Song(id: "lib:\(item.persistentID)", url: item.assetURL!, title: nonEmptyTitle(item.title, fallback: "Bilinmeyen"),
             artist: item.artist, albumArtist: item.albumArtist, album: item.albumTitle,
             trackNumber: item.albumTrackNumber, duration: item.playbackDuration,
             artwork: { [weak item] size in item?.artwork?.image(at: size) })
    }

    private static func song(fromFile url: URL) -> Song {
        let asset = AVURLAsset(url: url)
        let common = asset.commonMetadata
        let id3 = asset.metadata(forFormat: .id3Metadata)
        func value(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) -> AVMetadataItem? {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first
        }
        let artworkData = value(common, .commonIdentifierArtwork)?.dataValue
        let track = value(id3, .id3MetadataTrackNumber)?.stringValue?.split(separator: "/").first.flatMap { Int($0) } ?? 0
        let image = artworkData.flatMap(UIImage.init(data:))
        return Song(id: "file:\(url.lastPathComponent)", url: url,
                    title: nonEmptyTitle(value(common, .commonIdentifierTitle)?.stringValue,
                                         fallback: url.deletingPathExtension().lastPathComponent),
                    artist: value(common, .commonIdentifierArtist)?.stringValue,
                    albumArtist: value(id3, .id3MetadataBand)?.stringValue,
                    album: value(common, .commonIdentifierAlbumName)?.stringValue,
                    trackNumber: track, duration: CMTimeGetSeconds(asset.duration),
                    artwork: { _ in image })
    }

    private static func nonEmptyTitle(_ title: String?, fallback: String) -> String {
        Song.nonEmpty(title) ?? fallback
    }
}
