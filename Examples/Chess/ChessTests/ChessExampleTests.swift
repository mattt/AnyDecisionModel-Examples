import AnyDecisionModel
import Foundation
import Testing

@testable import Chess

actor DecisionRecorder {
    var calls: [[Question]] = []

    func append(_ questions: [Question]) {
        calls.append(questions)
    }
}

struct FakeDecisionModel: DecisionModel {
    enum Behavior: Sendable {
        case first
        case malformed
        case delayed(Duration)
    }

    var behavior: Behavior = .first
    let recorder: DecisionRecorder
    var modelID: String { "fake" }
    var capabilities = DecisionCapabilities(
        maximumChoiceOptions: 26,
        maximumScoreLevels: 5
    )

    func makeExecutor() -> any DecisionModelExecutor {
        Executor(model: self)
    }

    struct Executor: DecisionModelExecutor {
        let model: FakeDecisionModel

        func decide(_ questions: [Question], about state: DecisionState) async throws
            -> DecisionSession.Response
        {
            await model.recorder.append(questions)
            if case .delayed(let duration) = model.behavior {
                try await Task.sleep(for: duration)
            }
            let answers: [Answer] = questions.map { question in
                switch question {
                case .score(_, let levels):
                    let probabilities = levels.indices.map { $0 == 2 ? 1.0 : 0.0 }
                    return .score(value: 2, probabilities: probabilities, confidence: 1)
                case .choice(_, let options):
                    let selected = model.behavior == .malformed ? "illegal" : options[0].name
                    let probabilities = Dictionary(uniqueKeysWithValues: options.enumerated().map {
                        ($0.element.name, $0.offset == 0 ? 1.0 : 0.0)
                    })
                    return .choice(name: selected, probabilities: probabilities, confidence: 1)
                case .binary:
                    return .binary(probability: 0.5)
                }
            }
            return .init(modelID: model.modelID, answers: answers)
        }
    }
}

extension FakeDecisionModel.Behavior: Equatable {}

@Suite("Chess model decisions")
struct ChessExampleTests {
    @Test func zeroLegalMovesDoesNotCallTheModel() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(recorder: recorder))
        let game = try #require(Game(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"))
        await #expect(throws: ChessDecisionError.terminalPosition) {
            _ = try await service.decide(in: game)
        }
        #expect(await recorder.calls.isEmpty)
    }

    @Test func oneLegalMoveAdvancesWithoutAChoiceQuestion() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(recorder: recorder))
        let game = try #require(Game(fen: "7k/8/5K2/6Q1/8/8/8/8 b - - 0 1"))
        #expect(ChessRules.legalMoves(in: game).count == 1)
        let result = try await service.decide(in: game)
        #expect(result.move.uci == "h8h7")
        #expect(result.groups.isEmpty)
        #expect(await recorder.calls.count == 1)
    }

    @Test func exactly26MovesUseOneCompleteGroup() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(recorder: recorder))
        let game = try #require(Game(
            fen: "rnbqkbnr/ppp1pppp/3p4/6B1/8/3P4/PPP1PPPP/RN1QKBNR b KQkq - 1 2"
        ))
        #expect(ChessRules.legalMoves(in: game).count == 26)
        let result = try await service.decide(in: game)
        #expect(result.groups.count == 1)
        #expect(result.groups[0].probabilities.count == 26)
    }

    @Test func largeMoveSetCoversEveryMoveAndRunsAFinal() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(recorder: recorder))
        let game = try #require(Game(
            fen: "r3k2r/p1ppqpb1/bn2pnp1/2pP4/1p2P3/2N2N2/PPQBBPPP/R3K2R w KQkq - 0 1"
        ))
        let legalIDs = Set(ChessRules.legalMoves(in: game).map(\.uci))
        #expect(legalIDs.count == 45)
        let result = try await service.decide(in: game)
        let firstRound = result.groups.filter { $0.round == 1 }
        #expect(firstRound.map(\.probabilities.count) == [26, 19])
        #expect(Set(firstRound.flatMap(\.probabilities).map(\.moveID)) == legalIDs)
        #expect(result.groups.filter { $0.round == 2 }.count == 1)
    }

    @Test func promotionIdentifiersAndScorePerspectiveReachTheModel() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(recorder: recorder))
        let game = try #require(Game(fen: "4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        _ = try await service.decide(in: game)
        let calls = await recorder.calls
        let questions = calls.flatMap { $0 }
        let choiceOptions = questions.compactMap { question -> [ChoiceOption]? in
            guard case .choice(_, let options) = question else { return nil }
            return options
        }.flatMap { $0 }
        #expect(Set(choiceOptions.map(\.name)).isSuperset(of: [
            "a7a8q", "a7a8r", "a7a8b", "a7a8n",
        ]))
        let score = try #require(questions.first { question in
            if case .score = question { return true }
            return false
        })
        guard case .score(let instructions, let levels) = score else { return }
        #expect(
            instructions
                == "Assess the position before the move from Black's advantage to White's advantage."
        )
        #expect(levels == PositionAssessment.levels)
    }

    @Test func positionStateContainsRequiredContext() throws {
        var game = Game()
        game = try ChessRules.applying(uci: "e2e4", to: game)
        let state = ChessDecisionService.state(for: game)
        #expect(state.contains(game.asciiBoard))
        #expect(state.contains("FEN: \(game.fen)"))
        #expect(state.contains("Side to move: black"))
        #expect(state.contains("Side to move is in check: no"))
        #expect(state.contains("1. e2e4"))
    }

    @Test func malformedResponseIsRejected() async {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(
            behavior: .malformed,
            recorder: recorder
        ))
        await #expect(throws: (any Error).self) {
            _ = try await service.decide(in: Game())
        }
    }

    @Test func cancellationStopsARequest() async {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(
            behavior: .delayed(.seconds(10)),
            recorder: recorder
        ))
        let task = Task { try await service.decide(in: Game()) }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test @MainActor func resetDiscardsAStaleSelfPlayResult() async throws {
        let recorder = DecisionRecorder()
        let service = ChessDecisionService(model: FakeDecisionModel(
            behavior: .delayed(.milliseconds(100)),
            recorder: recorder
        ))
        let controller = ChessGameController(service: service)
        controller.setMode(.selfPlay)
        controller.toggleSelfPlay()
        await Task.yield()
        controller.newGame()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.game == Game())
        #expect(!controller.isThinking)
        #expect(!controller.isRunning)
    }
}
