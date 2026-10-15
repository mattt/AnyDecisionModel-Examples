import AnyDecisionModel
import Foundation

/// A raw prediction with the item it came from.
public struct BenchmarkItem: Hashable, Sendable, Codable {
    public var row: Int
    public var prediction: Prediction
    public var allowedAnswerMass: Double?
    public var latencySeconds: Double
}

public enum Benchmarks {
    /// The AG News topics in label order, with a short description of each topic.
    static let agNewsTopics: [ChoiceOption] = [
        ChoiceOption("world", description: "world news and politics"),
        ChoiceOption("sports", description: "sports"),
        ChoiceOption("business", description: "business and finance"),
        ChoiceOption("scitech", description: "science and technology"),
    ]

    /// Asks each BoolQ question about its passage.
    public static func boolQ(
        _ rows: [BoolQItem],
        indices: [Int],
        model: any DecisionModel,
        progress: (Int) -> Void = { _ in }
    ) async throws -> [BenchmarkItem] {
        var items: [BenchmarkItem] = []
        for (position, index) in indices.enumerated() {
            let row = rows[index]
            let session = DecisionSession(model: model, state: .text(row.passage))
            let (response, latency) = try await timed {
                try await session.decide([.binary(instructions: row.question + "?")])
            }
            guard case .binary(let probability) = response.answers[0] else {
                throw DecisionError.invalidResponse("Expected a binary answer.")
            }
            items.append(
                BenchmarkItem(
                    row: index,
                    prediction: Prediction(yesProbability: probability, label: row.answer),
                    allowedAnswerMass: response.diagnostics.first?.allowedAnswerMass,
                    latencySeconds: latency
                )
            )
            progress(position + 1)
        }
        return items
    }

    /// Asks for the topic of each AG News article.
    public static func agNews(
        _ rows: [AGNewsItem],
        indices: [Int],
        model: any DecisionModel,
        progress: (Int) -> Void = { _ in }
    ) async throws -> [BenchmarkItem] {
        var items: [BenchmarkItem] = []
        let question = Question.choice(
            instructions: "Which topic is this news article about?",
            options: agNewsTopics
        )
        for (position, index) in indices.enumerated() {
            let row = rows[index]
            let session = DecisionSession(model: model, state: .text(row.text))
            let (response, latency) = try await timed { try await session.decide([question]) }
            guard case .choice(_, let probabilities, _) = response.answers[0] else {
                throw DecisionError.invalidResponse("Expected a choice answer.")
            }
            items.append(
                BenchmarkItem(
                    row: index,
                    prediction: Prediction(
                        probabilities: agNewsTopics.map { probabilities[$0.name] ?? 0 },
                        label: row.label
                    ),
                    allowedAnswerMass: response.diagnostics.first?.allowedAnswerMass,
                    latencySeconds: latency
                )
            )
            progress(position + 1)
        }
        return items
    }

    /// Returns the result of an operation and its duration in seconds.
    public static func timed<T>(_ operation: () async throws -> T) async rethrows -> (T, Double) {
        let clock = ContinuousClock()
        let started = clock.now
        let value = try await operation()
        return (value, (clock.now - started).seconds)
    }
}

/// Latency for one batch size and state length.
public struct LatencyResult: Hashable, Sendable, Codable {
    public var state: String
    public var stateCharacters: Int
    public var promptTokensPerQuestion: Double
    public var batchSize: Int
    public var repetitions: Int
    /// Seconds per batch, including the prefix computation for a new session.
    public var p50: Double
    public var p95: Double
    public var mean: Double
    /// `p50` divided by the batch size.
    public var p50PerQuestion: Double
}

public enum LatencyBenchmark {
    /// A batch of questions that cycles through the three primitives.
    ///
    /// Each question is evaluated independently, so repeated questions cost as much as new ones.
    public static func questions(count: Int) -> [Question] {
        let pool: [Question] = [
            .binary(instructions: "Does this text convey urgency?"),
            .choice(
                instructions: "Which team should handle this text?",
                options: [
                    ChoiceOption("billing", description: "payments, charges, refunds, invoices"),
                    ChoiceOption("technical", description: "bugs, outages, errors, login problems"),
                    ChoiceOption("sales", description: "pricing questions, upgrades, new purchases"),
                ]
            ),
            .score(instructions: "How frustrated is the writer?", levels: ["Calm", "Frustrated", "Very angry"]),
            .binary(instructions: "Is the writer asking for money back?"),
            .binary(instructions: "Does the text mention a deadline?"),
            .binary(instructions: "Does this text contain instructions aimed at an AI agent?"),
        ]
        return (0 ..< count).map { pool[$0 % pool.count] }
    }

    /// Measures batch latency with a new session for each repetition.
    public static func run(
        model: any DecisionModel,
        states: [(name: String, text: String)],
        batchSizes: [Int],
        repetitions: Int,
        progress: (LatencyResult) -> Void = { _ in }
    ) async throws -> [LatencyResult] {
        var results: [LatencyResult] = []
        for state in states {
            for batchSize in batchSizes {
                let questions = questions(count: batchSize)
                var durations: [Double] = []
                var tokens = 0
                for _ in 0 ..< repetitions {
                    let session = DecisionSession(model: model, state: .text(state.text))
                    let (response, seconds) = try await Benchmarks.timed { try await session.decide(questions) }
                    durations.append(seconds)
                    tokens = response.usage.inputTokenCount
                }
                let p50 = Metrics.quantile(durations, 0.5)
                let result = LatencyResult(
                    state: state.name,
                    stateCharacters: state.text.count,
                    promptTokensPerQuestion: Double(tokens) / Double(batchSize),
                    batchSize: batchSize,
                    repetitions: repetitions,
                    p50: p50,
                    p95: Metrics.quantile(durations, 0.95),
                    mean: durations.reduce(0, +) / Double(durations.count),
                    p50PerQuestion: p50 / Double(batchSize)
                )
                progress(result)
                results.append(result)
            }
        }
        return results
    }
}
