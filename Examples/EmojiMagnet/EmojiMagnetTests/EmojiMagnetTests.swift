import AnyDecisionModel
import Foundation
import Testing

@testable import EmojiMagnet

/// Records model calls and controls failures.
actor ModelScript {
    struct Call: Sendable {
        var phrase: String
        var itemIDs: [String]
        var questions: [Question]
    }

    var calls: [Call] = []
    var loads = 0
    var failingLoads = 0
    var failingDecisions = 0
    private var running = 0
    private(set) var maximumRunning = 0

    func setFailures(loads: Int = 0, decisions: Int = 0) {
        failingLoads = loads
        failingDecisions = decisions
    }

    func load() throws {
        loads += 1
        if failingLoads > 0 {
            failingLoads -= 1
            throw DecisionError.modelUnavailable("offline")
        }
    }

    func begin(_ call: Call) throws {
        calls.append(call)
        running += 1
        maximumRunning = max(maximumRunning, running)
        if failingDecisions > 0 {
            failingDecisions -= 1
            running -= 1
            throw DecisionError.invalidResponse("fixture failure")
        }
    }

    func end() {
        running -= 1
    }

    func phrases() -> [String] {
        calls.map(\.phrase).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

/// A model that answers from a table of phrases.
struct TableDecisionModel: DecisionModel {
    var matches: [String: Set<String>]
    var probability = 0.9
    var delay: Duration = .zero
    /// Whether a request finishes even after its task is cancelled, like an MLX forward pass.
    var ignoresCancellation = false
    let script: ModelScript

    var modelID: String { "table" }
    var capabilities: DecisionCapabilities { DecisionCapabilities() }

    func makeExecutor() -> any DecisionModelExecutor {
        Executor(model: self)
    }

    struct Executor: DecisionModelExecutor {
        let model: TableDecisionModel

        func prewarm(for state: DecisionState) async throws {
            try await model.script.load()
        }

        func decide(_ questions: [Question], about state: DecisionState) async throws
            -> DecisionSession.Response
        {
            guard case .text(let text) = state,
                let line = text.split(separator: "\n").first
            else { throw DecisionError.invalidResponse("state") }
            let phrase = String(line.dropFirst("Phrase: ".count))
            let itemIDs = questions.map { question in
                EmojiCatalog.items.first { EmojiMatchService.question(for: $0, phrase: phrase) == question }?.id ?? "?"
            }
            try await model.script.begin(.init(phrase: phrase, itemIDs: itemIDs, questions: questions))
            if model.ignoresCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + model.delay.timeInterval) {
                        continuation.resume()
                    }
                }
            } else if model.delay > .zero {
                do {
                    try await Task.sleep(for: model.delay)
                } catch {
                    await model.script.end()
                    throw error
                }
            }
            await model.script.end()
            let matches = model.matches[phrase] ?? []
            let answers = itemIDs.map { Answer.binary(probability: matches.contains($0) ? model.probability : 0.1) }
            return .init(modelID: model.modelID, answers: answers)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

let clothing: Set<String> = [
    "coat", "scarf", "gloves", "socks", "boot", "jeans",
    "t-shirt", "shorts", "bikini", "flip-flop", "sun-hat", "sunglasses",
]
let winterClothing: Set<String> = ["coat", "scarf", "gloves", "socks", "boot"]

@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
func makeController(
    _ model: TableDecisionModel,
    debounce: Duration = .zero
) -> EmojiMagnetController {
    EmojiMagnetController(service: EmojiMatchService(model: model), debounce: debounce)
}

@Suite("Default model")
@MainActor
struct DefaultModelTests {
    @Test func usesJevWhenTheAPIKeyIsSet() {
        let model = EmojiMagnetController.defaultModel(environment: [
            "TYPESAFE_AI_API_KEY": "test-token"
        ])

        #expect(model.modelID == "jev-latest")
    }

    @Test func usesMLXWithoutAnAPIKey() {
        let model = EmojiMagnetController.defaultModel(environment: [:])

        #expect(model.modelID == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    }
}

@Suite("Matching service")
struct EmojiMatchServiceTests {
    @Test func sendsTheWholeCatalogInOneJevRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogJevURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = EmojiMatchService(model: JevDecisionModel(
            baseURL: URL(string: "https://jev.invalid")!,
            apiKey: "test-token",
            session: session,
            retryPolicy: .never
        ))
        let groups = Locked<[[MatchResult]]>([])
        try await service.evaluate("things you wear", items: EmojiCatalog.items) { results in
            groups.withLock { $0.append(results) }
        }
        let results = try #require(groups.withLock { $0.count == 1 ? $0.first : nil })
        #expect(results.map(\.itemID) == EmojiCatalog.items.map(\.id))
        #expect(results.map(\.probability) == EmojiCatalog.items.indices.map { Double($0) / 1_000 })
    }

    @Test func emptyCatalogMakesNoRequests() async throws {
        let script = ModelScript()
        let service = EmojiMatchService(model: TableDecisionModel(matches: [:], script: script))
        try await service.evaluate("things you wear", items: []) { _ in
            Issue.record("An empty catalog must not produce results.")
        }
        #expect(await script.calls.isEmpty)
    }

    @Test func asksOneBinaryQuestionPerItemInGroupsOf16() async throws {
        let script = ModelScript()
        let service = EmojiMatchService(model: TableDecisionModel(matches: [:], script: script))
        let items = Array(EmojiCatalog.items.prefix(20))
        let groups = Locked<[[MatchResult]]>([])
        try await service.evaluate("things you wear", items: items) { results in
            groups.withLock { $0.append(results) }
        }
        #expect(groups.withLock { $0.map(\.count) } == [16, 4])
        #expect(groups.withLock { $0.flatMap { $0.map(\.itemID) } } == items.map(\.id))

        let calls = await script.calls
        #expect(calls.map(\.phrase) == ["things you wear", "things you wear"])
        #expect(calls.flatMap(\.itemIDs) == items.map(\.id))
        let coat = try #require(calls.first?.questions.first)
        guard case .binary(let instructions, let criteria) = coat else {
            Issue.record("Expected a binary question")
            return
        }
        #expect(instructions == "Statement: a heavy winter coat fits the description \"things you wear\". Is this statement true?")
        #expect(criteria == nil)
        #expect(EmojiMatchService.state(for: "food that is not sweet").hasPrefix("Phrase: food that is not sweet\n"))
    }

    @Test func thresholdIsStrictlyAboveOneHalf() {
        #expect(!MatchResult(itemID: "coat", probability: 0.5).isMatch)
        #expect(MatchResult(itemID: "coat", probability: 0.500_1).isMatch)
        #expect(!MatchResult(itemID: "coat", probability: 0.1).isMatch)
    }

    @Test func catalogHasDistinctItems() {
        let items = EmojiCatalog.items
        #expect(items.count == 343)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(Set(items.map(\.glyph)).count == items.count)
        #expect(Set(items.map(\.description)).count == items.count)
        #expect(clothing.isSubset(of: Set(items.map(\.id))))
        #expect(EmojiCatalog.animals.count == 124)
        #expect(Set(EmojiCatalog.animals).isSubset(of: Set(items)))
    }
}

/// Checks the full Jev request and returns a distinct probability for each item.
private final class CatalogJevURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    body.append(buffer, count: count)
                }
            }
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let questions = try #require(json["questions"] as? [String: [String: Any]])
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/systemone")
            #expect(questions.count == EmojiCatalog.items.count)
            #expect(json["state"] as? String == EmojiMatchService.state(for: "things you wear"))
            for (index, item) in EmojiCatalog.items.enumerated() {
                #expect(questions[String(index)]?["type"] as? String == "noul")
                #expect(questions[String(index)]?["instructions"] as? String ==
                    "Statement: \(item.description) fits the description \"things you wear\". Is this statement true?")
            }
            let answers = Dictionary(uniqueKeysWithValues: EmojiCatalog.items.indices.map {
                (String($0), ["noul": Double($0) / 1_000])
            })
            let data = try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "answers": answers])
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Controller")
@MainActor
struct EmojiMagnetControllerTests {
    @Test func loadsOnceAndShowsProgressUntilThePhraseIsComplete() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing],
            delay: .milliseconds(30),
            script: script
        ))
        controller.start()
        controller.start()
        #expect(controller.isLoading)
        controller.setPhrase("things you wear")
        try await waitUntil { controller.evaluatedIDs.count == EmojiMatchService.groupSize }
        #expect(controller.isEvaluating)
        #expect(controller.attractedIDs == clothing.intersection(controller.evaluatedIDs))
        #expect(!controller.attractedIDs.isEmpty)

        try await waitUntil { !controller.isEvaluating }
        #expect(controller.attractedIDs == clothing)
        #expect(controller.evaluatedIDs.count == EmojiCatalog.items.count)
        #expect(await script.loads == 1)
        #expect(await script.maximumRunning == 1)
    }

    @Test func probabilityAtTheThresholdDoesNotAttract() async throws {
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing],
            probability: 0.5,
            script: ModelScript()
        ))
        controller.start()
        controller.setPhrase("things you wear")
        try await waitUntil { controller.evaluatedIDs.count == EmojiCatalog.items.count && !controller.isEvaluating }
        #expect(controller.attractedIDs.isEmpty)
        #expect(controller.probabilities["coat"] == 0.5)
    }

    @Test func refinementReleasesItemsAndBroadeningRecoversThem() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing, "things you wear in winter": winterClothing],
            delay: .milliseconds(10),
            script: script
        ))
        controller.start()
        controller.setPhrase("things you wear")
        try await waitUntil { !controller.isLoading && !controller.isEvaluating && !controller.attractedIDs.isEmpty }
        #expect(controller.attractedIDs == clothing)

        controller.setPhrase("things you wear in winter")
        try await waitUntil { controller.isEvaluating }
        // Earlier matches stay attracted until they receive their new results.
        #expect(controller.attractedIDs == clothing)
        try await waitUntil { !controller.isEvaluating }
        #expect(controller.attractedIDs == winterClothing)

        // The earlier matches are evaluated first.
        let refinement = await script.calls.filter { $0.phrase == "things you wear in winter" }
        let firstIDs = refinement.first?.itemIDs.prefix(clothing.count) ?? []
        #expect(Set(firstIDs) == clothing)

        controller.setPhrase("things you wear")
        try await waitUntil { controller.isEvaluating }
        try await waitUntil { !controller.isEvaluating }
        #expect(controller.attractedIDs == clothing)
    }

    @Test func clearingReleasesEveryItemImmediately() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing],
            delay: .milliseconds(20),
            script: script
        ))
        controller.start()
        controller.setPhrase("things you wear")
        try await waitUntil { !controller.attractedIDs.isEmpty }
        #expect(controller.isEvaluating)

        controller.clear()
        #expect(controller.phrase.isEmpty)
        #expect(controller.attractedIDs.isEmpty)
        #expect(!controller.isEvaluating)
        let callsAtClear = await script.calls.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.attractedIDs.isEmpty)
        // At most the running group finishes after the clear.
        #expect(await script.calls.count <= callsAtClear + 1)
    }

    @Test func typingWaitsForAPauseBeforeEvaluating() async throws {
        let script = ModelScript()
        let controller = makeController(
            TableDecisionModel(matches: ["things": clothing], script: script),
            debounce: .milliseconds(100)
        )
        controller.start()
        try await waitUntil { controller.isLoaded }
        for phrase in ["t", "th", "thi", "things"] {
            controller.setPhrase(phrase)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isEvaluating)
        try await waitUntil { !controller.isEvaluating && controller.attractedIDs == clothing }
        #expect(await script.phrases() == ["things"])
    }

    @Test func aNewPhraseCancelsTheRunningEvaluationAndRunsOnlyTheNewest() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing, "animals": ["dog", "cat", "penguin"]],
            delay: .milliseconds(40),
            script: script
        ))
        controller.start()
        controller.setPhrase("things you wear")
        try await waitUntil { controller.evaluatedIDs.count >= EmojiMatchService.groupSize }
        controller.setPhrase("food")
        controller.setPhrase("animals")
        try await waitUntil { controller.evaluatingPhrase == "animals" }
        try await waitUntil { !controller.isEvaluating }

        #expect(controller.attractedIDs == ["dog", "cat", "penguin"])
        let phrases = await script.phrases()
        #expect(phrases.first == "things you wear")
        #expect(phrases.last == "animals")
        #expect(!phrases.contains("food"))
        let obsoleteCalls = await script.calls.filter { $0.phrase == "things you wear" }.count
        #expect(obsoleteCalls < EmojiCatalog.items.count / EmojiMatchService.groupSize)
        #expect(await script.maximumRunning == 1)
    }

    @Test func obsoleteResponsesAreDiscarded() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing],
            delay: .milliseconds(60),
            ignoresCancellation: true,
            script: script
        ))
        controller.start()
        try await waitUntil { controller.isLoaded }
        controller.setPhrase("things you wear")
        try await waitUntil { controller.isEvaluating }
        try await Task.sleep(for: .milliseconds(20))
        // The first group matches, but the phrase changes before it returns.
        controller.setPhrase("rocks")
        try await waitUntil { controller.evaluatingPhrase == "rocks" }
        try await waitUntil(timeout: .seconds(10)) { !controller.isEvaluating }
        #expect(controller.attractedIDs.isEmpty)
        #expect(controller.evaluatedIDs.count == EmojiCatalog.items.count)
        #expect(await script.maximumRunning == 1)
    }

    @Test func evaluationFailureReleasesItemsAndRetryRecovers() async throws {
        let script = ModelScript()
        let controller = makeController(TableDecisionModel(
            matches: ["things you wear": clothing, "things you wear in winter": winterClothing],
            script: script
        ))
        controller.start()
        controller.setPhrase("things you wear")
        try await waitUntil { !controller.isEvaluating && controller.attractedIDs == clothing }

        await script.setFailures(decisions: 1)
        controller.setPhrase("things you wear in winter")
        try await waitUntil { controller.errorMessage != nil }
        #expect(controller.attractedIDs.isEmpty)
        #expect(!controller.isEvaluating)

        controller.retry()
        #expect(controller.errorMessage == nil)
        try await waitUntil { !controller.isEvaluating }
        #expect(controller.attractedIDs == winterClothing)
    }

    @Test func loadFailureShowsAnErrorAndRetryLoadsAgain() async throws {
        let script = ModelScript()
        await script.setFailures(loads: 1)
        let controller = makeController(TableDecisionModel(matches: ["things you wear": clothing], script: script))
        controller.start()
        try await waitUntil { controller.errorMessage != nil }
        #expect(!controller.isLoaded)
        #expect(!controller.isLoading)

        controller.retry()
        #expect(controller.isLoading)
        try await waitUntil { controller.isLoaded }
        #expect(controller.errorMessage == nil)
        controller.setPhrase("things you wear")
        try await waitUntil { !controller.isEvaluating && controller.attractedIDs == clothing }
        #expect(await script.loads == 2)
    }

    @Test func typingAfterALoadFailureLoadsAgain() async throws {
        let script = ModelScript()
        await script.setFailures(loads: 1)
        let controller = makeController(TableDecisionModel(matches: ["things you wear": clothing], script: script))
        controller.start()
        try await waitUntil { controller.errorMessage != nil }
        controller.setPhrase("things you wear")
        try await waitUntil { controller.isLoaded && controller.attractedIDs == clothing }
        #expect(controller.errorMessage == nil)
        #expect(await script.loads == 2)
    }

    @Test func closingCancelsPendingWork() async throws {
        let script = ModelScript()
        let controller = makeController(
            TableDecisionModel(matches: ["things you wear": clothing], delay: .milliseconds(20), script: script),
            debounce: .milliseconds(50)
        )
        controller.start()
        try await waitUntil { controller.isLoaded }
        controller.setPhrase("things you wear")
        controller.close()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await script.calls.isEmpty)
        #expect(!controller.isEvaluating)
    }
}

@Suite("Layout")
struct MagnetLayoutTests {
    @Test func gatheredItemsFormCenteredRowsBelowTheField() {
        let size = CGSize(width: 470, height: 500)
        let columns = MagnetLayout.columns(width: size.width, spacing: MagnetLayout.gatherSpacing)
        #expect(columns == 5)
        let targets = MagnetLayout.gatherTargets(count: 7, in: size)
        #expect(targets.count == 7)
        #expect(Set(targets.prefix(5).map(\.y)).count == 1)
        #expect(Set(targets.suffix(2).map(\.y)).count == 1)
        #expect(targets[5].y < targets[0].y)
        #expect(abs((targets[0].x + targets[4].x) / 2 - size.width / 2) < 0.001)
        #expect(abs((targets[5].x + targets[6].x) / 2 - size.width / 2) < 0.001)
        #expect(targets.allSatisfy { $0.x > 0 && $0.x < size.width && $0.y < size.height })
    }

    @Test func manyGatheredItemsMoveCloserToFitTheScene() {
        let size = CGSize(width: 720, height: 429)
        #expect(MagnetLayout.fittingGatherSpacing(count: 6, in: size) == MagnetLayout.gatherSpacing)
        let spacing = MagnetLayout.fittingGatherSpacing(count: EmojiCatalog.items.count, in: size)
        #expect(spacing < MagnetLayout.gatherSpacing)
        let scale = MagnetLayout.itemScale(count: EmojiCatalog.items.count, in: size)
        #expect(spacing >= MagnetLayout.itemSize * scale)
        let targets = MagnetLayout.gatherTargets(count: EmojiCatalog.items.count, in: size)
        #expect(targets.allSatisfy { $0.y > 0 })
    }

    @Test func staticPileStartsAtTheBottom() {
        let size = CGSize(width: 1_000, height: 600)
        let pile = MagnetLayout.pilePositions(count: 48, in: size)
        #expect(pile.map(\.y).min() == MagnetLayout.margin / 2 + MagnetLayout.pileSpacing / 2)
        #expect(pile.allSatisfy { $0.y < size.height / 2 })
    }

    @Test func fullCatalogFitsTheSmallestWindowWithReduceMotion() {
        let size = CGSize(width: 720, height: 429)
        let bounds = CGRect(origin: .zero, size: size)
        let count = EmojiCatalog.items.count
        let side = MagnetLayout.itemSize * MagnetLayout.itemScale(count: count, in: size)
        for positions in [
            MagnetLayout.pilePositions(count: count, in: size),
            MagnetLayout.gatherTargets(count: count, in: size),
        ] {
            #expect(positions.count == count)
            for point in positions {
                let frame = CGRect(
                    x: point.x - side / 2,
                    y: point.y - side / 2,
                    width: side,
                    height: side
                )
                #expect(bounds.contains(frame))
            }
        }
    }
}

/// A small lock for collecting results from a `Sendable` closure.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
