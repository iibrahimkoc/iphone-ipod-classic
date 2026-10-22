import Foundation

/// Liked and disliked songs, kept in the music folder as ".ratings.json" so the Mac's iPod Müzik
/// app can read them (it lists the disliked ones for deleting). Each entry also keeps the title
/// and artist, since Finder-synced songs can't be looked up from the Mac.
final class Ratings: ObservableObject {
    enum Rating: Int, Codable {
        case disliked = -1
        case liked = 1
    }

    struct Entry: Codable {
        var rating: Rating
        var title: String
        var artist: String
    }

    static let file = SongLibrary.folder.appendingPathComponent(".ratings.json")

    @Published private(set) var entries: [String: Entry] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func rating(of song: Song) -> Rating? { entries[song.id]?.rating }

    func set(_ rating: Rating?, for song: Song) {
        guard self.rating(of: song) != rating else { return }
        entries[song.id] = rating.map { Entry(rating: $0, title: song.title, artist: song.artistName) }
        save()
    }

    /// Drops the entries of songs that are gone (e.g. deleted from the Mac).
    func prune(keeping songs: [Song]) {
        let ids = Set(songs.map(\.id))
        let kept = entries.filter { ids.contains($0.key) }
        guard kept.count != entries.count, !songs.isEmpty else { return }
        entries = kept
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: Shuffle

    /// A random order that leans toward what was liked: disliked songs are left out, liked ones
    /// come up about four times as often, and unrated songs by an artist with liked songs come up
    /// more often (less often for disliked artists). Each song gets the key u^(1/weight) for a
    /// random u, and sorting by it is a weighted shuffle (Efraimidis–Spirakis), so every song
    /// still plays once per round.
    func shuffled(_ songs: [Song]) -> [Song] {
        var likes: [String: Int] = [:]
        var dislikes: [String: Int] = [:]
        for song in songs {
            switch rating(of: song) {
            case .liked?: likes[song.artistName.lowercased(), default: 0] += 1
            case .disliked?: dislikes[song.artistName.lowercased(), default: 0] += 1
            case nil: break
            }
        }
        let keyed = songs.compactMap { song -> (key: Double, song: Song)? in
            let weight = self.weight(of: song, likes: likes, dislikes: dislikes)
            guard weight > 0 else { return nil }
            return (pow(Double.random(in: Double.leastNonzeroMagnitude ..< 1), 1 / weight), song)
        }
        return spreadArtists(keyed.sorted { $0.key > $1.key }.map(\.song))
    }

    private func weight(of song: Song, likes: [String: Int], dislikes: [String: Int]) -> Double {
        switch rating(of: song) {
        case .disliked?: return 0
        case .liked?: return 4
        case nil:
            let artist = song.artistName.lowercased()
            let liked = Double(min(likes[artist] ?? 0, 3))
            let disliked = Double(min(dislikes[artist] ?? 0, 3))
            return (1 + 0.5 * liked) / (1 + 0.5 * disliked)
        }
    }

    /// Liked artists come up often, so two of their songs can land side by side; this moves the
    /// second one down to the next song by someone else.
    private func spreadArtists(_ songs: [Song]) -> [Song] {
        var result = songs
        guard result.count > 2 else { return result }
        for index in 1 ..< result.count where result[index].artistName == result[index - 1].artistName {
            if let other = result[(index + 1)...].firstIndex(where: { $0.artistName != result[index - 1].artistName }) {
                result.swapAt(index, other)
            }
        }
        return result
    }
}
