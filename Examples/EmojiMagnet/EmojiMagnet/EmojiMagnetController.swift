import AnyDecisionModel
import Foundation
import Observation

@MainActor
@Observable
final class EmojiMagnetController {
    let catalog: [EmojiItem]
    /// The text in the field.
    private(set) var phrase = ""
    /// The items that rise toward the field.
    private(set) var attractedIDs: Set<EmojiItem.ID> = []
    /// The latest probability for each item, for the current or previous phrase.
    private(set) var probabilities: [EmojiItem.ID: Double] = [:]
    private(set) var isLoading = false
    private(set) var isLoaded = false
    private(set) var errorMessage: String?
    /// The phrase that the model is evaluating or will evaluate next, if any.
    private(set) var evaluatingPhrase: String?
    /// The items that have a result for `evaluatingPhrase`.
    private(set) var evaluatedIDs: Set<EmojiItem.ID> = []

    private let service: EmojiMatchService
    private let debounce: Duration
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    /// The newest phrase that waits for the model or for the running operation to end.
    private var pendingPhrase: String?
    /// Changes whenever earlier results and errors become obsolete.
    private var generation = 0

    init(
        service: EmojiMatchService,
        catalog: [EmojiItem] = EmojiCatalog.items,
        debounce: Duration = .milliseconds(250)
    ) {
        self.service = service
        self.catalog = catalog
        self.debounce = debounce
    }

    convenience init() {
        self.init(service: EmojiMatchService(model: Self.defaultModel()))
    }

    static func defaultModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any DecisionModel {
        if let apiKey = JevDecisionModel.environmentAPIKey(from: environment) {
            return JevDecisionModel(apiKey: apiKey)
        }

        // Every phrase reuses one session's prefix for all of its questions.
        // The batched MLX path masks cached prefixes with an explicit causal mask.
        return MLXDecisionModel(
            modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            prefixCaching: true
        )
    }

    var isEvaluating: Bool { evaluatingPhrase != nil }
    var attractedItems: [EmojiItem] { catalog.filter { attractedIDs.contains($0.id) } }

    /// Loads the model once. Call this when the window opens.
    func start() {
        guard !isLoaded, loadTask == nil else { return }
        isLoading = true
        let requestGeneration = generation
        loadTask = Task { [weak self, service] in
            do {
                try await service.load()
                try Task.checkCancellation()
                guard let self else { return }
                self.loadTask = nil
                self.isLoading = false
                self.isLoaded = true
                self.startPendingEvaluation()
            } catch {
                guard let self else { return }
                self.loadTask = nil
                self.isLoading = false
                guard self.generation == requestGeneration, !(error is CancellationError) else { return }
                self.fail(with: error)
            }
        }
    }

    /// Updates the phrase and schedules an evaluation after a pause in typing.
    func setPhrase(_ text: String) {
        guard text != phrase else { return }
        phrase = text
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            releaseAll()
            return
        }
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.request(trimmed)
        }
    }

    /// Clears the phrase and releases every item at once.
    func clear() {
        phrase = ""
        debounceTask?.cancel()
        releaseAll()
    }

    func retry() {
        guard errorMessage != nil else { return }
        errorMessage = nil
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            start()
        } else {
            request(trimmed)
        }
    }

    /// Cancels pending work when the window closes.
    func close() {
        generation += 1
        debounceTask?.cancel()
        loadTask?.cancel()
        inferenceTask?.cancel()
        pendingPhrase = nil
        evaluatingPhrase = nil
    }

    private func request(_ phrase: String) {
        generation += 1
        errorMessage = nil
        pendingPhrase = phrase
        evaluatingPhrase = phrase
        evaluatedIDs = []
        if inferenceTask != nil {
            // The running operation ends soon and then starts the pending phrase.
            inferenceTask?.cancel()
        } else if isLoaded {
            startPendingEvaluation()
        } else {
            start()
        }
    }

    private func startPendingEvaluation() {
        guard inferenceTask == nil, isLoaded, let phrase = pendingPhrase else { return }
        pendingPhrase = nil
        let requestGeneration = generation
        // Previous matches come first so that items that stay attracted confirm quickly.
        let items = catalog.filter { attractedIDs.contains($0.id) } + catalog.filter { !attractedIDs.contains($0.id) }
        inferenceTask = Task { [weak self, service] in
            do {
                try await service.evaluate(phrase, items: items) { [weak self] results in
                    await self?.apply(results, generation: requestGeneration)
                }
                self?.finishEvaluation(generation: requestGeneration, error: nil)
            } catch {
                self?.finishEvaluation(generation: requestGeneration, error: error)
            }
        }
    }

    private func apply(_ results: [MatchResult], generation requestGeneration: Int) {
        guard generation == requestGeneration else { return }
        for result in results {
            probabilities[result.itemID] = result.probability
            evaluatedIDs.insert(result.itemID)
            if result.isMatch {
                attractedIDs.insert(result.itemID)
            } else {
                attractedIDs.remove(result.itemID)
            }
        }
    }

    private func finishEvaluation(generation requestGeneration: Int, error: (any Error)?) {
        inferenceTask = nil
        if generation == requestGeneration {
            if let error, !(error is CancellationError) {
                fail(with: error)
            } else {
                evaluatingPhrase = nil
            }
        }
        startPendingEvaluation()
    }

    private func fail(with error: any Error) {
        errorMessage = error.localizedDescription
        pendingPhrase = nil
        evaluatingPhrase = nil
        attractedIDs = []
    }

    /// Cancels evaluation and releases every item.
    /// A running model operation ends in the background, and its results are discarded.
    private func releaseAll() {
        generation += 1
        inferenceTask?.cancel()
        pendingPhrase = nil
        evaluatingPhrase = nil
        evaluatedIDs = []
        errorMessage = nil
        attractedIDs = []
        probabilities = [:]
    }
}
