import Foundation

/// Talks to Muzik/muzik.sh, which does the iTunes lookup and the tagging.
enum Tagger {
    struct Info: Codable {
        var trackName: String
        var artistName: String
        var collectionName: String
        var artworkUrl100: String?
        var releaseDate: String?
        var primaryGenreName: String?
        var trackNumber: Int?
        var trackCount: Int?

        var artworkURL: URL? {
            artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "300x300bb")) }
        }
    }

    struct Lookup: Decodable {
        let path: String
        let source: String
        let info: Info
    }

    private struct Apply: Encodable {
        let path: String
        let info: Info
    }

    struct Result: Decodable {
        let path: String
        let ok: Bool
        let error: String?
    }

    /// The repo's Muzik folder, baked in at build time (see build-app.sh).
    private static var script: URL {
        let folder = Bundle.main.object(forInfoDictionaryKey: "MuzikFolder") as? String ?? ""
        return URL(fileURLWithPath: folder).appendingPathComponent("muzik.sh")
    }

    static func lookup(_ file: URL) async throws -> Lookup {
        let output = try await run(["--json", file.path])
        guard let first = try JSONDecoder().decode([Lookup].self, from: output).first else {
            throw CocoaError(.fileReadUnknown)
        }
        return first
    }

    static func apply(_ items: [(URL, Info)]) async throws -> [Result] {
        let input = try JSONEncoder().encode(items.map { Apply(path: $0.0.path, info: $0.1) })
        return try JSONDecoder().decode([Result].self, from: try await run(["--uygula"], input: input))
    }

    private static func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = script
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let stdin = Pipe()
            process.standardInput = stdin
            process.terminationHandler = { _ in
                continuation.resume(returning: stdout.fileHandleForReading.readDataToEndOfFile())
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(input ?? Data())
                try? stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
