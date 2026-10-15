import AnyDecisionModel
import Foundation

/// The model's answer for one item.
struct MatchResult: Hashable, Sendable {
    var itemID: EmojiItem.ID
    /// The probability that the item satisfies the whole phrase.
    var probability: Double

    init(itemID: EmojiItem.ID, probability: Double) {
        self.itemID = itemID
        self.probability = probability
    }

    /// Whether the item rises toward the text field.
    var isMatch: Bool { probability > EmojiMatchService.threshold }
}

/// Asks a decision model which catalog items match a phrase.
struct EmojiMatchService: Sendable {
    /// The number of items in each request to a local model.
    ///
    /// The MLX model evaluates up to 16 prompts in one forward pass,
    /// so each group takes one pass after the shared prompt text.
    static let groupSize = 16
    /// Probabilities above this value are matches.
    static let threshold = 0.5

    private let model: any DecisionModel

    init(model: any DecisionModel) {
        self.model = model
    }

    /// Loads the model weights. The first call can download them.
    func load() async throws {
        try await DecisionSession(model: model, state: .text(Self.state(for: ""))).prewarm()
    }

    /// Evaluates every item against a phrase.
    ///
    /// Jev receives all items in one request.
    /// Other models receive groups of ``groupSize`` items.
    /// Items are evaluated in the order given.
    /// The service calls `onGroup` after each group completes,
    /// so that the caller can show results before the whole catalog is done.
    ///
    /// - Throws: `CancellationError` if the task is cancelled, or the model's error.
    func evaluate(
        _ phrase: String,
        items: [EmojiItem],
        onGroup: @Sendable ([MatchResult]) async -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        let session = DecisionSession(model: model, state: .text(Self.state(for: phrase)))
        let requestSize = model is JevDecisionModel ? items.count : Self.groupSize
        for start in stride(from: 0, to: items.count, by: requestSize) {
            try Task.checkCancellation()
            let group = items[start ..< min(start + requestSize, items.count)]
            let response = try await session.decide(group.map { Self.question(for: $0, phrase: phrase) })
            try Task.checkCancellation()
            let results = try zip(group, response.answers).map { item, answer in
                guard case .binary(let probability) = answer else {
                    throw DecisionError.invalidResponse("Expected a binary answer for \(item.id).")
                }
                return MatchResult(itemID: item.id, probability: probability)
            }
            await onGroup(results)
        }
    }

    /// The state holds the phrase and the matching rules, which every question shares.
    ///
    /// The model evaluates the state once for each phrase and reuses it for every question.
    static func state(for phrase: String) -> String {
        """
        Phrase: \(phrase)
        An item matches only if it fits the phrase as a whole, including every qualifier. \
        A negation in the phrase excludes the items it names.
        """
    }

    /// Asks whether an item fits the phrase, with both in the same statement.
    ///
    /// This wording reduced disagreements with Jev on separate evaluation phrases.
    static func question(for item: EmojiItem, phrase: String) -> Question {
        .binary(instructions: "Statement: \(item.description) fits the description \"\(phrase)\". Is this statement true?")
    }
}
