import Foundation

/// Stockfish, bundled as its own executable next to the app's (see build.sh) and spoken to over
/// UCI on its stdin/stdout. It also knows the rules: the legal moves come from "go perft 1" and
/// the board and check from "d", so the app has no move generator of its own. Every call blocks,
/// so they run on the game's queue.
final class ChessEngine {
    struct Position {
        let fen: String
        let legal: [String]
        let check: Bool
    }

    private var pid: pid_t = 0
    private let input: Int32
    private let output: Int32
    private var pending: [UInt8] = []

    init?() {
        guard let path = Bundle.main.path(forAuxiliaryExecutable: "stockfish") else { return nil }
        // A dead engine must not take the app down with it on the next write.
        signal(SIGPIPE, SIG_IGN)
        var toEngine: [Int32] = [0, 0]
        var fromEngine: [Int32] = [0, 0]
        guard pipe(&toEngine) == 0, pipe(&fromEngine) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, toEngine[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromEngine[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, toEngine[1])
        posix_spawn_file_actions_addclose(&actions, fromEngine[0])
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        let status = posix_spawn(&pid, path, &actions, nil, argv, environ)
        free(argv[0])
        posix_spawn_file_actions_destroy(&actions)
        close(toEngine[0])
        close(fromEngine[1])
        input = toEngine[1]
        output = fromEngine[0]
        guard status == 0 else {
            pid = 0
            return nil
        }
        send("uci")
        guard lines(until: { $0 == "uciok" }) != nil else { return nil }
        // One thread keeps the phone responsive; a small hash is plenty for short searches.
        send("setoption name Threads value 1")
        send("setoption name Hash value 16")
        send("isready")
        guard lines(until: { $0 == "readyok" }) != nil else { return nil }
    }

    deinit {
        if pid > 0 {
            kill(pid, SIGTERM)
            waitpid(pid, nil, 0)
        }
        close(input)
        close(output)
    }

    /// The position after `moves` from the start: its FEN, the legal moves and whether the side to
    /// move is in check. Nil if the engine is gone.
    func position(after moves: [String]) -> Position? {
        send(positionCommand(moves))
        send("go perft 1")
        send("isready")
        guard let perft = lines(until: { $0 == "readyok" }) else { return nil }
        send("d")
        send("isready")
        guard let dump = lines(until: { $0 == "readyok" }) else { return nil }
        // "e2e4: 1"; the "Nodes searched: 29" line is too long to be a move.
        let legal = perft.compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let move = String(line[..<colon])
            return (4 ... 5).contains(move.count) ? move : nil
        }
        guard let fen = dump.first(where: { $0.hasPrefix("Fen: ") }) else { return nil }
        let checkers = dump.first { $0.hasPrefix("Checkers:") }?.dropFirst(9).trimmingCharacters(in: .whitespaces) ?? ""
        return Position(fen: String(fen.dropFirst(5)), legal: legal, check: !checkers.isEmpty)
    }

    /// The engine's reply to `moves`, played at `skill` (0–20) after thinking for `time` ms.
    func bestMove(after moves: [String], skill: Int, time: Int) -> String? {
        send("setoption name Skill Level value \(skill)")
        send(positionCommand(moves))
        send("go movetime \(time)")
        guard let line = lines(until: { $0.hasPrefix("bestmove") })?.last else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count > 1, parts[1] != "(none)" else { return nil }
        return String(parts[1])
    }

    private func positionCommand(_ moves: [String]) -> String {
        moves.isEmpty ? "position startpos" : "position startpos moves " + moves.joined(separator: " ")
    }

    private func send(_ command: String) {
        let bytes = Array((command + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(input, $0.baseAddress, $0.count) }
    }

    /// Reads lines up to and including the first one `done` accepts; nil if the engine is gone.
    private func lines(until done: (String) -> Bool) -> [String]? {
        var lines: [String] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                lines.append(line)
                if done(line) { return lines }
                continue
            }
            let count = read(output, &chunk, chunk.count)
            guard count > 0 else { return nil }
            pending += chunk[..<count]
        }
    }
}

/// A game against Stockfish, played with the wheel: turning walks your pieces that can move, the
/// center picks one up, turning then walks its target squares and the center plays the move. MENU
/// puts the piece back. You play white. The moves are saved, so a game survives quitting the app.
final class ChessGame: ObservableObject {
    enum Level: Int, CaseIterable {
        case easy, medium, hard, master

        var title: String { ["Kolay", "Orta", "Zor", "Usta"][rawValue] }
        /// Stockfish's Skill Level (0–20) and how long it thinks, in ms.
        var skill: Int { [0, 5, 12, 20][rawValue] }
        var time: Int { [200, 400, 800, 1500][rawValue] }
    }

    enum State: Equatable {
        case loading
        case choosingPiece
        /// A piece is picked up from this square.
        case choosingTarget(String)
        case thinking
        case over(String)
        case failed
    }

    private static let movesKey = "chessMoves"
    private static let levelKey = "chessLevel"

    /// Squares from a8 to h1 in reading order; uppercase is white, as in FEN.
    @Published private(set) var board: [Character?] = Array(repeating: nil, count: 64)
    @Published private(set) var state = State.loading
    @Published private(set) var inCheck = false
    /// Index into `options`.
    @Published private(set) var cursor = 0
    @Published private(set) var moves: [String]
    @Published private(set) var level: Level

    private var legal: [String] = []
    /// How often each position (FEN without the move counters) occurred, for threefold repetition.
    private var seen: [String: Int] = [:]
    private var seenPly = -1
    private var lastFrom: String?
    private var engine: ChessEngine?
    private let queue = DispatchQueue(label: "chess")
    /// Bumped on every open and close, so an answer from a game that was left is dropped.
    private var generation = 0

    init() {
        moves = UserDefaults.standard.stringArray(forKey: Self.movesKey) ?? []
        level = (UserDefaults.standard.object(forKey: Self.levelKey) as? Int).flatMap(Level.init) ?? .medium
    }

    /// A game that was left unfinished.
    var canResume: Bool { !(UserDefaults.standard.stringArray(forKey: Self.movesKey) ?? []).isEmpty }

    func start(_ level: Level) {
        self.level = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey)
        moves = []
        seen = [:]
        seenPly = -1
        lastFrom = nil
        save()
        open()
    }

    func open() {
        generation += 1
        state = .loading
        update()
    }

    /// Leaving the game stops Stockfish, so its memory goes back to the music.
    func close() {
        generation += 1
        queue.async { self.engine = nil }
    }

    // MARK: Wheel

    /// The squares (or moves, while a piece is picked up) the wheel walks through.
    var options: [String] {
        switch state {
        case .choosingPiece:
            return Array(Set(legal.map { String($0.prefix(2)) })).sorted { Self.index($0) < Self.index($1) }
        case .choosingTarget(let from):
            let promotions = "qrbn"
            return legal.filter { $0.hasPrefix(from) }.sorted {
                let a = Self.index(Self.target($0)), b = Self.index(Self.target($1))
                if a != b { return a < b }
                return promotions.firstIndex(of: $0.last!)! < promotions.firstIndex(of: $1.last!)!
            }
        default:
            return []
        }
    }

    /// False when there was nothing to move through.
    func scroll(_ delta: Int) -> Bool {
        let count = options.count
        guard count > 1 else { return false }
        cursor = ((cursor + delta) % count + count) % count
        return true
    }

    func select() {
        switch state {
        case .choosingPiece:
            let options = self.options
            guard options.indices.contains(cursor) else { return }
            lastFrom = options[cursor]
            state = .choosingTarget(options[cursor])
            cursor = 0
        case .choosingTarget:
            let options = self.options
            guard options.indices.contains(cursor) else { return }
            play(options[cursor])
        case .over:
            start(level)
        case .failed:
            open()
        case .loading, .thinking:
            break
        }
    }

    /// MENU while a piece is picked up puts it back; false when there was none, so MENU leaves.
    func back() -> Bool {
        guard case .choosingTarget(let from) = state else { return false }
        state = .choosingPiece
        cursor = options.firstIndex(of: from) ?? 0
        return true
    }

    // MARK: What the board shows

    /// The square under the cursor.
    var cursorSquare: String? {
        let options = self.options
        guard options.indices.contains(cursor) else { return nil }
        if case .choosingTarget = state { return Self.target(options[cursor]) }
        return options[cursor]
    }

    var pickedUp: String? {
        if case .choosingTarget(let from) = state { return from }
        return nil
    }

    var targets: Set<String> {
        guard case .choosingTarget = state else { return [] }
        return Set(options.map(Self.target))
    }

    /// The piece a pawn becomes with the move under the cursor.
    var promotion: Character? {
        guard case .choosingTarget = state, options.indices.contains(cursor), options[cursor].count == 5 else { return nil }
        return options[cursor].last
    }

    var lastMove: (from: String, to: String)? {
        moves.last.map { (String($0.prefix(2)), Self.target($0)) }
    }

    func piece(at square: String) -> Character? { board[Self.index(square)] }

    static func square(_ index: Int) -> String {
        let file = Character(UnicodeScalar(UInt8(97 + index % 8)))
        return "\(file)\(8 - index / 8)"
    }

    static func index(_ square: String) -> Int {
        let bytes = Array(square.utf8)
        return (8 - Int(bytes[1] - 48)) * 8 + Int(bytes[0] - 97)
    }

    private static func target(_ move: String) -> String {
        String(move.dropFirst(2).prefix(2))
    }

    // MARK: Playing

    private func play(_ move: String) {
        moves.append(move)
        save()
        state = .thinking
        update()
    }

    private func save() {
        UserDefaults.standard.set(moves, forKey: Self.movesKey)
    }

    private func update() {
        let moves = self.moves, generation = self.generation
        queue.async {
            if self.engine == nil { self.engine = ChessEngine() }
            let position = self.engine?.position(after: moves)
            if position == nil { self.engine = nil }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                guard let position = position else { return self.state = .failed }
                self.show(position)
            }
        }
    }

    private func show(_ position: ChessEngine.Position) {
        let fields = position.fen.split(separator: " ")
        board = []
        for character in fields[0] where character != "/" {
            if let empty = character.wholeNumberValue {
                board += Array(repeating: nil, count: empty)
            } else {
                board.append(character)
            }
        }
        inCheck = position.check
        legal = position.legal
        let key = fields.prefix(4).joined(separator: " ")
        if seenPly != moves.count {
            seenPly = moves.count
            seen[key, default: 0] += 1
        }

        if let result = result(position, halfmoves: fields.count > 4 ? Int(fields[4]) ?? 0 : 0, repeated: seen[key, default: 0] >= 3) {
            state = .over(result)
            UserDefaults.standard.removeObject(forKey: Self.movesKey)
        } else if moves.count % 2 == 1 {
            think()
        } else {
            state = .choosingPiece
            cursor = lastFrom.flatMap { options.firstIndex(of: $0) } ?? 0
        }
    }

    private func result(_ position: ChessEngine.Position, halfmoves: Int, repeated: Bool) -> String? {
        if position.legal.isEmpty {
            guard position.check else { return "Pat · Berabere" }
            return moves.count % 2 == 0 ? "Mat oldun" : "Mat! Kazandın"
        }
        if halfmoves >= 100 { return "50 hamle · Berabere" }
        if repeated { return "Üç tekrar · Berabere" }
        let rest = board.compactMap { $0 }.filter { $0 != "k" && $0 != "K" }
        if rest.isEmpty || (rest.count == 1 && "nNbB".contains(rest[0])) { return "Yetersiz taş · Berabere" }
        return nil
    }

    private func think() {
        state = .thinking
        let moves = self.moves, generation = self.generation, level = self.level
        queue.async {
            let move = self.engine?.bestMove(after: moves, skill: level.skill, time: level.time)
            if move == nil { self.engine = nil }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                guard let move = move else { return self.state = .failed }
                self.moves.append(move)
                self.save()
                self.update()
            }
        }
    }
}
