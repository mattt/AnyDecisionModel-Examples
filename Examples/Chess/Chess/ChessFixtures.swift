#if DEBUG
import AnyDecisionModel
import Foundation

/// Deterministic scenarios for inspecting the interface without downloading a model.
///
/// Launch a Debug build with `-ChessFixture <name>`, for example:
/// `open "AnyDecisionModel Chess.app" --args -ChessFixture grouped`.
enum ChessFixture: String, CaseIterable {
    /// The model stays in the thinking state.
    case thinking
    /// The model fails, which shows the error and Retry.
    case failure
    /// The model chooses among more than 26 moves, which produces grouped results.
    case grouped
    /// A human White pawn can promote on a8.
    case promotion
    /// White is checkmated after four moves.
    case checkmate
    /// Self-play with a fast fixture model.
    case selfPlay = "self-play"

    static var current: ChessFixture? {
        UserDefaults.standard.string(forKey: "ChessFixture").flatMap(Self.init(rawValue:))
    }

    @MainActor
    func makeController() -> ChessGameController {
        let behavior: FixtureDecisionModel.Behavior = switch self {
        case .thinking: .delay(.seconds(3_600))
        case .failure: .fail
        case .selfPlay: .delay(.milliseconds(400))
        default: .delay(.milliseconds(300))
        }
        let (mode, fen, moves): (PlayMode, String?, [String]) = switch self {
        case .thinking, .failure: (.humanBlack, nil, [])
        case .grouped: (.humanBlack, nil, ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "g8f6"])
        case .promotion: (.humanWhite, "4k3/P7/8/8/8/8/8/4K3 w - - 0 1", [])
        case .checkmate: (.humanWhite, nil, ["f2f3", "e7e5", "g2g4", "d8h4"])
        case .selfPlay: (.selfPlay, nil, [])
        }
        let service = ChessDecisionService(model: FixtureDecisionModel(behavior: behavior))
        let game = fen.flatMap(Game.init(fen:)) ?? Game()
        let controller = (try? ChessGameController(
            service: service,
            mode: mode,
            startingGame: game,
            moves: moves
        )) ?? ChessGameController(service: service)
        controller.startModelTurnIfNeeded()
        return controller
    }
}

private struct FixtureError: LocalizedError {
    var errorDescription: String? {
        "The model could not load. Check the network connection and try again."
    }
}

/// A decision model that returns fixed, decreasing probabilities.
struct FixtureDecisionModel: DecisionModel {
    enum Behavior: Sendable {
        case delay(Duration)
        case fail
    }

    var behavior: Behavior
    var modelID: String { "fixture" }
    var capabilities: DecisionCapabilities {
        DecisionCapabilities(maximumChoiceOptions: 26, maximumScoreLevels: 5)
    }

    func makeExecutor() -> any DecisionModelExecutor {
        Executor(behavior: behavior, modelID: modelID)
    }

    struct Executor: DecisionModelExecutor {
        let behavior: Behavior
        let modelID: String

        func decide(_ questions: [Question], about state: DecisionState) async throws
            -> DecisionSession.Response
        {
            switch behavior {
            case .delay(let duration): try await Task.sleep(for: duration)
            case .fail: throw FixtureError()
            }
            let answers: [Answer] = questions.map { question in
                switch question {
                case .score(_, let levels):
                    let weights = [0.04, 0.16, 0.46, 0.26, 0.08]
                    let probabilities = levels.indices.map { weights[$0 % weights.count] }
                    let total = probabilities.reduce(0, +)
                    let normalized = probabilities.map { $0 / total }
                    let score = normalized.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
                    return .score(value: score, probabilities: normalized, confidence: 0.46)
                case .choice(_, let options):
                    // Prefer a different option in each group so that the results vary.
                    let preferred = options.count / 3
                    let weights = options.indices.map { 1 / Double(1 + abs($0 - preferred)) }
                    let total = weights.reduce(0, +)
                    let probabilities = Dictionary(uniqueKeysWithValues: options.indices.map {
                        (options[$0].name, weights[$0] / total)
                    })
                    return .choice(
                        name: options[preferred].name,
                        probabilities: probabilities,
                        confidence: weights[preferred] / total
                    )
                case .binary:
                    return .binary(probability: 0.5)
                }
            }
            return .init(modelID: modelID, answers: answers)
        }
    }
}
#endif
