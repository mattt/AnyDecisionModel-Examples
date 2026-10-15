#if DEBUG
import AnyDecisionModel
import Foundation

/// Deterministic scenarios for inspecting the interface without downloading a model.
///
/// Launch a Debug build with `-EmojiMagnetFixture <name>`, for example:
/// `open "AnyDecisionModel Emoji Magnet.app" --args -EmojiMagnetFixture matches`.
enum EmojiMagnetFixture: String, CaseIterable {
    /// The model loads and answers quickly from a fixed table of phrases.
    case matches
    /// The model never finishes loading.
    case loading
    /// The model loads, then fails to evaluate, which shows the error and Retry.
    case failure

    static var current: EmojiMagnetFixture? {
        UserDefaults.standard.string(forKey: "EmojiMagnetFixture").flatMap(Self.init(rawValue:))
    }

    @MainActor
    func makeController() -> EmojiMagnetController {
        let behavior: FixtureDecisionModel.Behavior = switch self {
        case .matches: .answer(delay: .milliseconds(120))
        case .loading: .loadForever
        case .failure: .fail
        }
        return EmojiMagnetController(service: EmojiMatchService(model: FixtureDecisionModel(behavior: behavior)))
    }
}

private struct FixtureError: LocalizedError {
    var errorDescription: String? {
        "The model could not evaluate the phrase. Try again."
    }
}

/// A decision model that answers from a fixed table of phrases.
///
/// The table lists the matches for a few exact phrases.
/// Every other phrase matches nothing.
struct FixtureDecisionModel: DecisionModel {
    enum Behavior: Sendable {
        case answer(delay: Duration)
        case loadForever
        case fail
    }

    static let table: [String: Set<EmojiItem.ID>] = [
        "things you wear": [
            "coat", "scarf", "gloves", "socks", "boot", "jeans",
            "t-shirt", "shorts", "bikini", "flip-flop", "sun-hat", "sunglasses",
        ],
        "things you wear in winter": ["coat", "scarf", "gloves", "socks", "boot", "jeans"],
        "animals": Set(EmojiCatalog.animals.map(\.id)),
        "anything": Set(EmojiCatalog.items.map(\.id)),
    ]

    var behavior: Behavior
    var modelID: String { "fixture" }
    var capabilities: DecisionCapabilities { DecisionCapabilities() }

    func makeExecutor() -> any DecisionModelExecutor {
        Executor(behavior: behavior, modelID: modelID)
    }

    struct Executor: DecisionModelExecutor {
        let behavior: Behavior
        let modelID: String

        func prewarm(for state: DecisionState) async throws {
            switch behavior {
            case .loadForever: try await Task.sleep(for: .seconds(3_600))
            case .answer, .fail: try await Task.sleep(for: .milliseconds(600))
            }
        }

        func decide(_ questions: [Question], about state: DecisionState) async throws
            -> DecisionSession.Response
        {
            switch behavior {
            case .answer(let delay): try await Task.sleep(for: delay)
            case .loadForever: try await Task.sleep(for: .seconds(3_600))
            case .fail: throw FixtureError()
            }
            let fixture = FixtureDecisionModel.table.first { EmojiMatchService.state(for: $0.key) == state.text }
            let phrase = fixture?.key ?? ""
            let matches = fixture?.value ?? []
            let answers = questions.map { question in
                let item = EmojiCatalog.items.first { EmojiMatchService.question(for: $0, phrase: phrase) == question }
                return Answer.binary(probability: item.map { matches.contains($0.id) } == true ? 0.92 : 0.06)
            }
            return .init(modelID: modelID, answers: answers)
        }
    }
}

extension DecisionState {
    var text: String? {
        if case .text(let text) = self { text } else { nil }
    }
}
#endif
