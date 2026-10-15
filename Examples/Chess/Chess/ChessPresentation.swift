extension PlayMode {
    var title: String {
        switch self {
        case .humanWhite: "Play White"
        case .humanBlack: "Play Black"
        case .selfPlay: "Self-Play"
        }
    }

    /// The human player's color is at the bottom. Self-play shows White at the bottom.
    var defaultBottomColor: Piece.Color {
        self == .humanBlack ? .black : .white
    }
}

extension Piece.Color {
    var name: String { self == .white ? "White" : "Black" }
}

extension Piece {
    var name: String {
        "\(color.name.lowercased()) \(kind.rawValue)"
    }
}

extension Game.Outcome {
    var summary: String? {
        switch self {
        case .inProgress: nil
        case .checkmate(let winner): "Checkmate. \(winner.name) wins."
        case .stalemate: "Draw by stalemate."
        case .drawByRepetition: "Draw by threefold repetition."
        case .drawByFiftyMoveRule: "Draw by the fifty-move rule."
        case .drawByInsufficientMaterial: "Draw by insufficient material."
        }
    }
}

extension Game {
    /// The square of the side to move's king when that king is in check.
    var checkedKingSquare: Board.Square? {
        guard ChessRules.isInCheck(turn, board: board) else { return nil }
        return board.pieces.first { $0.value == Piece(color: turn, kind: .king) }?.key
    }
}

/// One numbered row of the move history.
struct MoveHistoryRow: Hashable, Identifiable {
    var number: Int
    /// The index into the move list for White's move, if the row has one.
    var whiteIndex: Int?
    var white: String?
    var blackIndex: Int?
    var black: String?

    var id: Int { number }

    static func rows(
        from notations: [String],
        startingTurn: Piece.Color = .white,
        startingFullmove: Int = 1
    ) -> [MoveHistoryRow] {
        var rows: [MoveHistoryRow] = []
        for (index, notation) in notations.enumerated() {
            let ply = index + (startingTurn == .black ? 1 : 0)
            let number = startingFullmove + ply / 2
            if ply.isMultiple(of: 2) {
                rows.append(MoveHistoryRow(number: number, whiteIndex: index, white: notation))
            } else if rows.last?.number == number {
                rows[rows.count - 1].blackIndex = index
                rows[rows.count - 1].black = notation
            } else {
                rows.append(MoveHistoryRow(number: number, blackIndex: index, black: notation))
            }
        }
        return rows
    }
}

/// A model decision with move notation from the position that the model assessed.
struct DecisionSummary: Hashable {
    struct Option: Hashable, Identifiable {
        var moveID: String
        var notation: String
        var probability: Double
        var isSelected: Bool
        var id: String { moveID }
    }

    struct Group: Hashable, Identifiable {
        var round: Int
        var group: Int
        var selectedNotation: String
        var options: [Option]
        var id: String { "\(round)-\(group)" }
    }

    var moveNotation: String
    var mover: Piece.Color
    var assessedFEN: String
    var expectedLevel: Double
    var levelProbabilities: [Double]
    var mostLikelyLevel: String
    var elapsed: Duration
    var groups: [Group]

    init(decision: ChessDecision, before game: Game) {
        let moves = Dictionary(
            ChessRules.legalMoves(in: game).map { ($0.uci, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func notation(_ moveID: String) -> String {
            moves[moveID].map(game.notation(for:)) ?? moveID
        }

        moveNotation = game.notation(for: decision.move)
        mover = game.turn
        assessedFEN = decision.assessedFEN
        expectedLevel = decision.assessment.value
        levelProbabilities = decision.assessment.probabilities
        mostLikelyLevel = decision.assessment.mostLikelyLevel
        elapsed = decision.elapsed
        groups = decision.groups.map { group in
            Group(
                round: group.round,
                group: group.group,
                selectedNotation: notation(group.selectedMoveID),
                options: group.probabilities.map { item in
                    Option(
                        moveID: item.moveID,
                        notation: notation(item.moveID),
                        probability: item.probability,
                        isSelected: item.moveID == group.selectedMoveID
                    )
                }
            )
        }
    }
}

/// The squares that a player selects to make a move.
struct MoveSelection: Equatable {
    enum Outcome: Equatable {
        case none
        case move(Game.Move)
        case promotion([Game.Move])
    }

    private(set) var square: Board.Square?
    private(set) var moves: [Game.Move] = []

    var targets: Set<Board.Square> { Set(moves.map(\.to)) }

    /// Selects a piece, changes the selection, or chooses a destination.
    mutating func activate(
        _ square: Board.Square,
        in game: Game,
        legalMoves: (Board.Square) -> [Game.Move]
    ) -> Outcome {
        if self.square == square {
            clear()
            return .none
        }
        if let piece = game.board[square], piece.color == game.turn {
            let moves = legalMoves(square)
            if moves.isEmpty {
                clear()
            } else {
                self.square = square
                self.moves = moves
            }
            return .none
        }
        let matching = moves.filter { $0.to == square }
        clear()
        if matching.count > 1, matching.allSatisfy({ $0.promotionKind != nil }) {
            return .promotion(matching)
        }
        return matching.first.map(Outcome.move) ?? .none
    }

    mutating func clear() {
        square = nil
        moves = []
    }
}
