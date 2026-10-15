import AnyDecisionModel
import Foundation

enum ChessDecisionError: Error, Equatable, Sendable {
    case terminalPosition
    case selectedIllegalMove(String)
}

struct PositionAssessment: Hashable, Sendable {
    static let levels = [
        "Clear Black advantage",
        "Slight Black advantage",
        "Equal position",
        "Slight White advantage",
        "Clear White advantage",
    ]

    var value: Double
    var probabilities: [Double]
    var mostLikelyLevel: String
    var confidence: Double

    init(score: Score) {
        value = score.value
        probabilities = score.probabilities
        mostLikelyLevel = score.levels[score.mostLikelyLevelIndex]
        confidence = score.confidence
    }
}

struct MoveChoiceGroup: Hashable, Sendable, Identifiable {
    struct Probability: Hashable, Sendable, Identifiable {
        var moveID: String
        var probability: Double
        var id: String { moveID }
    }

    var round: Int
    var group: Int
    var selectedMoveID: String
    var probabilities: [Probability]
    var confidence: Double
    var id: String { "\(round)-\(group)" }
}

struct ChessDecision: Hashable, Sendable {
    var move: Game.Move
    var assessedFEN: String
    var assessment: PositionAssessment
    var groups: [MoveChoiceGroup]
    var elapsed: Duration
}

actor ChessDecisionService {
    static let maximumGroupSize = 26

    private let model: any DecisionModel

    init(model: any DecisionModel) {
        self.model = model
    }

    func decide(in game: GameSnapshot) async throws -> ChessDecision {
        let legalMoves = ChessRules.legalMoves(in: game).sorted { $0.uci < $1.uci }
        guard !legalMoves.isEmpty else { throw ChessDecisionError.terminalPosition }

        let started = ContinuousClock.now
        let session = DecisionSession(model: model, state: .text(Self.state(for: game)))
        let score = try await session.score(
            "Assess the position before the move from Black's advantage to White's advantage.",
            levels: PositionAssessment.levels
        )
        try Task.checkCancellation()

        var candidates = legalMoves
        var groups: [MoveChoiceGroup] = []
        var round = 1
        while candidates.count > 1 {
            var winners: [Game.Move] = []
            for (groupIndex, chunk) in candidates.chunked(maximumCount: Self.maximumGroupSize).enumerated() {
                try Task.checkCancellation()
                if chunk.count == 1 {
                    winners.append(chunk[0])
                    continue
                }
                let options = chunk.map { move in
                    ChoiceOption(move.uci, description: Self.description(of: move, in: game))
                }
                let choice = try await session.choice(
                    "Choose the best legal move for \(game.turn.rawValue).",
                    from: options
                )
                guard let winner = chunk.first(where: { $0.uci == choice.value }) else {
                    throw ChessDecisionError.selectedIllegalMove(choice.value)
                }
                winners.append(winner)
                groups.append(MoveChoiceGroup(
                    round: round,
                    group: groupIndex + 1,
                    selectedMoveID: choice.value,
                    probabilities: choice.distribution.map {
                        .init(moveID: $0.option, probability: $0.probability)
                    },
                    confidence: choice.confidence
                ))
            }
            candidates = winners
            round += 1
        }

        try Task.checkCancellation()
        return ChessDecision(
            move: candidates[0],
            assessedFEN: game.fen,
            assessment: PositionAssessment(score: score),
            groups: groups,
            elapsed: started.duration(to: .now)
        )
    }

    static func state(for game: GameSnapshot) -> String {
        let check = ChessRules.isInCheck(game.turn, board: game.board) ? "yes" : "no"
        let history = game.coordinateMoveHistory.isEmpty ? "(none)" : game.coordinateMoveHistory
        return """
        Position:
        \(game.asciiBoard)

        FEN: \(game.fen)
        Side to move: \(game.turn.rawValue)
        Side to move is in check: \(check)
        Coordinate move history: \(history)
        """
    }

    private static func description(of move: Game.Move, in game: Game) -> String {
        "\(game.notation(for: move)): \(move.piece.color.rawValue) "
            + "\(move.piece.kind.rawValue) from \(move.from.notation) to \(move.to.notation)"
    }
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0 ..< Swift.min($0 + maximumCount, count)])
        }
    }
}
