import SwiftUI

/// The board on the left, the game's state on the right.
struct ChessView: View {
    @ObservedObject var game: ChessGame

    private static let names: [Character: String] = ["k": "Şah", "q": "Vezir", "r": "Kale", "b": "Fil", "n": "At", "p": "Piyon"]
    private static let light = Color(white: 0.93)
    private static let dark = Color(red: 0.56, green: 0.66, blue: 0.80)

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let side = min(h - 8, geo.size.width * 0.64)
            HStack(alignment: .top, spacing: 8) {
                board(square: side / 8)
                panel(h: h)
            }
            .foregroundColor(.black)
            .padding(4)
        }
    }

    // MARK: Board

    private func board(square: CGFloat) -> some View {
        let cursor = game.cursorSquare
        let pickedUp = game.pickedUp
        let targets = game.targets
        let last = game.lastMove
        return VStack(spacing: 0) {
            ForEach(0 ..< 8, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0 ..< 8, id: \.self) { column in
                        let index = row * 8 + column
                        let name = ChessGame.square(index)
                        let piece = game.board[index]
                        ZStack {
                            (row + column) % 2 == 0 ? Self.light : Self.dark
                            if name == last?.from || name == last?.to {
                                Color.yellow.opacity(0.35)
                            }
                            if game.inCheck, piece == (game.moves.count % 2 == 0 ? "K" : "k") {
                                Color.red.opacity(0.55)
                            }
                            if name == pickedUp {
                                Color(red: 0.98, green: 0.80, blue: 0.30)
                            }
                            if name == cursor {
                                highlight.opacity(0.9)
                            }
                            if let piece = piece {
                                glyph(piece, size: square)
                            }
                            if name == cursor, let promotion = game.promotion {
                                glyph(promotion.uppercased().first!, size: square * 0.5)
                                    .offset(x: square * 0.25, y: square * 0.25)
                            }
                            if targets.contains(name), name != cursor {
                                if piece == nil {
                                    Circle().fill(Color.black.opacity(0.28)).frame(width: square * 0.3, height: square * 0.3)
                                } else {
                                    Circle().stroke(Color.black.opacity(0.35), lineWidth: square * 0.08)
                                }
                            }
                        }
                        .frame(width: square, height: square)
                    }
                }
            }
        }
        .overlay(Rectangle().stroke(Color(white: 0.4), lineWidth: 1))
    }

    /// White pieces are the white-filled shape under the outline glyph; black ones the filled glyph.
    /// U+FE0E keeps them as text, not emoji.
    private func glyph(_ piece: Character, size: CGFloat) -> some View {
        let kinds = "kqrbnp"
        let offset = kinds.distance(from: kinds.startIndex, to: kinds.firstIndex(of: Character(piece.lowercased()))!)
        let filled = String(Array("♚♛♜♝♞♟")[offset]) + "\u{FE0E}"
        let outline = String(Array("♔♕♖♗♘♙")[offset]) + "\u{FE0E}"
        return ZStack {
            if piece.isUppercase {
                Text(filled).foregroundColor(.white)
                Text(outline).foregroundColor(.black)
            } else {
                Text(filled).foregroundColor(.black)
            }
        }
        .font(.system(size: size * 0.8))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    // MARK: Panel

    private func panel(h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.03) {
            HStack(spacing: 4) {
                Text(status).font(.system(size: h * 0.075, weight: .bold))
                if game.state == .thinking || game.state == .loading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            if let detail = detail {
                Text(detail).font(.system(size: h * 0.065, weight: .semibold))
            }
            Spacer(minLength: 0)
            captured(white: false, h: h)
            captured(white: true, h: h)
            Text("\(game.level.title) · \(game.moves.count / 2 + 1). hamle")
                .font(.system(size: h * 0.058, weight: .medium))
                .foregroundColor(Color(white: 0.4))
            Text(hint)
                .font(.system(size: h * 0.05))
                .foregroundColor(.gray)
        }
        .lineLimit(2)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 2)
    }

    private var status: String {
        switch game.state {
        case .loading: return "Açılıyor…"
        case .thinking: return "Düşünüyor…"
        case .choosingPiece, .choosingTarget: return game.inCheck ? "Şah! Sıra sende" : "Sıra sende"
        case .over(let result): return result
        case .failed: return "Stockfish açılamadı"
        }
    }

    /// "At g1 → f3" for what is under the cursor.
    private var detail: String? {
        guard let cursor = game.cursorSquare else { return nil }
        if let from = game.pickedUp, let piece = game.piece(at: from) {
            var text = "\(name(piece)) \(from) → \(cursor)"
            if let promotion = game.promotion { text += " (\(name(promotion)))" }
            return text
        }
        return game.piece(at: cursor).map { "\(name($0)) \(cursor)" }
    }

    private var hint: String {
        switch game.state {
        case .choosingPiece: return "Çevir: taş · Orta: al"
        case .choosingTarget: return "Çevir: kare · Orta: oyna · MENU: bırak"
        case .over: return "Orta: yeni oyun"
        case .failed: return "Orta: tekrar dene"
        case .loading, .thinking: return " "
        }
    }

    private func name(_ piece: Character) -> String {
        Self.names[Character(piece.lowercased())] ?? ""
    }

    /// The pieces of one color that are off the board.
    private func captured(white: Bool, h: CGFloat) -> some View {
        let start: [Character: Int] = ["q": 1, "r": 2, "b": 2, "n": 2, "p": 8]
        // As one line of text that shrinks to fit: white as outlines, black filled.
        let text = zip("qrbnp", white ? "♕♖♗♘♙" : "♛♜♝♞♟").map { kind, symbol -> String in
            let piece = white ? Character(kind.uppercased()) : kind
            let missing = (start[kind] ?? 0) - game.board.filter { $0 == piece }.count
            return String(repeating: String(symbol) + "\u{FE0E}", count: max(missing, 0))
        }.joined()
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: h * 0.08))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }
}
