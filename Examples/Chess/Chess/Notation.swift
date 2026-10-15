extension Game {
    init?(fen: String) {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }

        var board = Board()
        let ranks = fields[0].split(separator: "/")
        guard ranks.count == 8 else { return nil }
        for (rankOffset, text) in ranks.enumerated() {
            var fileIndex = 0
            for character in text {
                if let emptyCount = character.wholeNumberValue {
                    fileIndex += emptyCount
                    continue
                }
                guard fileIndex < 8,
                      let file = Board.File(index: fileIndex),
                      let rank = Board.Rank(rawValue: 8 - rankOffset),
                      let piece = Self.piece(for: character)
                else { return nil }
                board[Board.Square(file, rank)] = piece
                fileIndex += 1
            }
            guard fileIndex == 8 else { return nil }
        }

        guard let turn = Piece.Color(fenCode: fields[1]) else { return nil }
        var rights: Board.CastlingRights = []
        if fields[2].contains("K") { rights.insert(.whiteKingside) }
        if fields[2].contains("Q") { rights.insert(.whiteQueenside) }
        if fields[2].contains("k") { rights.insert(.blackKingside) }
        if fields[2].contains("q") { rights.insert(.blackQueenside) }
        let enPassant = fields[3] == "-" ? nil : Board.Square(notation: String(fields[3]))
        let halfmove = fields.count > 4 ? Int(fields[4]) ?? 0 : 0
        let fullmove = fields.count > 5 ? Int(fields[5]) ?? 1 : 1
        self.init(
            board: board,
            turn: turn,
            castlingRights: rights,
            enPassantSquare: enPassant,
            halfmoveClock: halfmove,
            fullmoveNumber: fullmove
        )
    }

    var fen: String {
        var ranks: [String] = []
        for rank in Board.Rank.allCases.reversed() {
            var text = ""
            var emptyCount = 0
            for file in Board.File.allCases {
                if let piece = board[Board.Square(file, rank)] {
                    if emptyCount > 0 {
                        text += String(emptyCount)
                        emptyCount = 0
                    }
                    text.append(piece.fenCharacter)
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 { text += String(emptyCount) }
            ranks.append(text)
        }

        var rights = ""
        if castlingRights.contains(.whiteKingside) { rights += "K" }
        if castlingRights.contains(.whiteQueenside) { rights += "Q" }
        if castlingRights.contains(.blackKingside) { rights += "k" }
        if castlingRights.contains(.blackQueenside) { rights += "q" }
        if rights.isEmpty { rights = "-" }
        return "\(ranks.joined(separator: "/")) \(turn.fenCode) \(rights) "
            + "\(enPassantSquare?.notation ?? "-") \(halfmoveClock) \(fullmoveNumber)"
    }

    var asciiBoard: String {
        var lines: [String] = []
        for rank in Board.Rank.allCases.reversed() {
            let pieces = Board.File.allCases.map { file in
                board[Board.Square(file, rank)].map { String($0.fenCharacter) } ?? "."
            }
            lines.append("\(rank.rawValue) \(pieces.joined(separator: " "))")
        }
        lines.append("  a b c d e f g h")
        return lines.joined(separator: "\n")
    }

    func notation(for move: Move) -> String {
        switch move.kind {
        case .castle(let side): return side.rawValue + checkSuffix(after: move)
        default: break
        }

        var notation = move.piece.sanLetter
        if move.piece.kind == .pawn, move.isCapture {
            notation += move.from.file.rawValue
        } else if move.piece.kind != .pawn {
            let others = ChessRules.legalMoves(in: self).filter {
                $0.from != move.from && $0.piece == move.piece && $0.to == move.to
            }
            if !others.isEmpty {
                let sharesFile = others.contains { $0.from.file == move.from.file }
                let sharesRank = others.contains { $0.from.rank == move.from.rank }
                if !sharesFile {
                    notation += move.from.file.rawValue
                } else if !sharesRank {
                    notation += String(move.from.rank.rawValue)
                } else {
                    notation += move.from.notation
                }
            }
        }
        if move.isCapture { notation += "x" }
        notation += move.to.notation
        if let promotion = move.promotionKind {
            notation += "=" + Piece(color: move.piece.color, kind: promotion).sanLetter
        }
        return notation + checkSuffix(after: move)
    }

    var coordinateMoveHistory: String {
        history.enumerated().map { index, move in
            index.isMultiple(of: 2) ? "\(index / 2 + 1). \(move.uci)" : move.uci
        }.joined(separator: " ")
    }

    private func checkSuffix(after move: Move) -> String {
        guard let next = try? ChessRules.applying(move, to: self),
              ChessRules.isInCheck(next.turn, board: next.board)
        else { return "" }
        return ChessRules.legalMoves(in: next).isEmpty ? "#" : "+"
    }

    private static func piece(for character: Character) -> Piece? {
        let color: Piece.Color = character.isUppercase ? .white : .black
        let kind: Piece.Kind? = switch character.lowercased() {
        case "p": .pawn
        case "r": .rook
        case "n": .knight
        case "b": .bishop
        case "q": .queen
        case "k": .king
        default: nil
        }
        return kind.map { Piece(color: color, kind: $0) }
    }
}

extension Piece.Color {
    var fenCode: String { self == .white ? "w" : "b" }

    init?(fenCode: Substring) {
        switch fenCode {
        case "w": self = .white
        case "b": self = .black
        default: return nil
        }
    }
}
