import AnyDecisionModel
import Foundation
import Testing

@testable import Chess

@Suite("Chess presentation and controls")
@MainActor
struct ChessPresentationTests {
    private func makeService(_ behavior: FakeDecisionModel.Behavior = .first) -> ChessDecisionService {
        ChessDecisionService(model: FakeDecisionModel(behavior: behavior, recorder: DecisionRecorder()))
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for a condition.", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func historyRowsPairWhiteAndBlackMoves() {
        let rows = MoveHistoryRow.rows(from: ["e4", "e5", "Nf3"])
        #expect(rows == [
            MoveHistoryRow(number: 1, whiteIndex: 0, white: "e4", blackIndex: 1, black: "e5"),
            MoveHistoryRow(number: 2, whiteIndex: 2, white: "Nf3"),
        ])

        let fromBlack = MoveHistoryRow.rows(from: ["Kh7", "Qg6+"], startingTurn: .black, startingFullmove: 40)
        #expect(fromBlack == [
            MoveHistoryRow(number: 40, blackIndex: 0, black: "Kh7"),
            MoveHistoryRow(number: 41, whiteIndex: 1, white: "Qg6+"),
        ])
    }

    @Test func humanAndModelMovesRecordNotationAndUCI() async throws {
        let controller = ChessGameController(service: makeService())
        let move = try #require(controller.legalMoves(from: .g1).first { $0.uci == "g1f3" })
        controller.makeHumanMove(move)
        #expect(controller.moveNotations == ["Nf3"])
        #expect(controller.isThinking)

        try await waitUntil { !controller.isThinking }
        let history = controller.game.history
        #expect(history.count == 2)
        #expect(controller.moveNotations.count == 2)
        #expect(controller.game.coordinateMoveHistory == "1. g1f3 \(history[1].uci)")
        let summary = try #require(controller.lastDecisionSummary)
        #expect(summary.mover == .black)
        #expect(summary.moveNotation == controller.moveNotations[1])
        #expect(controller.hasCompletedModelMove)
    }

    @Test func decisionSummaryKeepsGroupsAndUsesNotation() async throws {
        let game = try #require(Game(
            fen: "r3k2r/p1ppqpb1/bn2pnp1/2pP4/1p2P3/2N2N2/PPQBBPPP/R3K2R w KQkq - 0 1"
        ))
        let decision = try await makeService().decide(in: game)
        let summary = DecisionSummary(decision: decision, before: game)
        #expect(summary.groups.map(\.options.count) == decision.groups.map(\.probabilities.count))
        for group in summary.groups {
            #expect(group.options.filter(\.isSelected).count == 1)
            let selected = try #require(group.options.first { $0.isSelected })
            #expect(selected.notation == group.selectedNotation)
        }
        let castle = try #require(summary.groups[0].options.first { $0.moveID == "e1c1" })
        #expect(castle.notation == "O-O-O")
    }

    @Test func modeChangesResetOrientationAndFlipKeepsTheGame() {
        let controller = ChessGameController(service: makeService(.delayed(.seconds(10))))
        #expect(controller.bottomColor == .white)
        controller.flipBoard()
        #expect(controller.bottomColor == .black)
        #expect(controller.game == Game())

        controller.setMode(.humanBlack)
        #expect(controller.bottomColor == .black)
        controller.flipBoard()
        controller.setMode(.selfPlay)
        #expect(controller.bottomColor == .white)
        controller.close()
    }

    @Test func newGameClearsHistoryAndResults() async throws {
        let controller = ChessGameController(service: makeService())
        let move = try #require(controller.legalMoves(from: .e2).first { $0.uci == "e2e4" })
        controller.makeHumanMove(move)
        try await waitUntil { !controller.isThinking }
        #expect(controller.lastDecisionSummary != nil)

        controller.newGame()
        #expect(controller.game == Game())
        #expect(controller.moveNotations.isEmpty)
        #expect(controller.lastDecision == nil)
        #expect(controller.lastDecisionSummary == nil)
    }

    @Test func terminalPositionsDisableMovesAndSelfPlay() throws {
        let mate = try #require(Game(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"))
        let controller = try ChessGameController(service: makeService(), mode: .selfPlay, startingGame: mate)
        #expect(!controller.canToggleSelfPlay)
        #expect(!controller.canStep)
        controller.toggleSelfPlay()
        #expect(!controller.isRunning)
        #expect(!controller.isThinking)

        controller.setMode(.humanBlack)
        #expect(!controller.acceptsHumanMoves)
        #expect(!controller.isThinking)
    }

    @Test func selfPlayStopsRunningWhenTheGameEnds() async throws {
        let game = try #require(Game(fen: "4k3/8/8/8/8/8/8/R3K3 w - - 99 60"))
        let controller = try ChessGameController(service: makeService(), mode: .selfPlay, startingGame: game)
        controller.toggleSelfPlay()
        #expect(controller.isRunning)
        try await waitUntil { !controller.isThinking }
        #expect(controller.outcome == .drawByFiftyMoveRule)
        #expect(!controller.isRunning)
        #expect(!controller.canToggleSelfPlay)
        #expect(controller.moveNotations.count == 1)
    }

    @Test func modelTurnsBlockHumanSelection() {
        let controller = ChessGameController(service: makeService(.delayed(.seconds(10))))
        controller.setMode(.humanBlack)
        #expect(controller.isThinking)
        #expect(!controller.acceptsHumanMoves)
        #expect(controller.legalMoves(from: .e7).isEmpty)
        controller.close()
    }

    @Test func selectionChoosesMovesAndPromotions() throws {
        let game = Game()
        let legalMoves = { ChessRules.legalMoves(from: $0, in: game) }
        var selection = MoveSelection()

        #expect(selection.activate(.e7, in: game, legalMoves: legalMoves) == .none)
        #expect(selection.square == nil)

        #expect(selection.activate(.e2, in: game, legalMoves: legalMoves) == .none)
        #expect(selection.square == .e2)
        #expect(selection.targets == [.e3, .e4])

        #expect(selection.activate(.e2, in: game, legalMoves: legalMoves) == .none)
        #expect(selection.square == nil)

        _ = selection.activate(.e2, in: game, legalMoves: legalMoves)
        guard case .move(let move) = selection.activate(.e4, in: game, legalMoves: legalMoves) else {
            Issue.record("Expected a move.")
            return
        }
        #expect(move.uci == "e2e4")
        #expect(selection.square == nil)

        let promotion = try #require(Game(fen: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let promotionMoves = { ChessRules.legalMoves(from: $0, in: promotion) }
        _ = selection.activate(.a7, in: promotion, legalMoves: promotionMoves)
        guard case .promotion(let choices) = selection.activate(.a8, in: promotion, legalMoves: promotionMoves) else {
            Issue.record("Expected promotion choices.")
            return
        }
        #expect(Set(choices.map(\.uci)) == ["a7a8q", "a7a8r", "a7a8b", "a7a8n"])
    }
}
