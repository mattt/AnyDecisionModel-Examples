import AnyDecisionModel
import Foundation

/// A question in a fixture file.
///
/// Fixtures list options in order, which the Jev wire format cannot express,
/// so they use this type instead of ``Question``'s wire coding.
public struct FixtureQuestion: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case binary, choice, score
    }

    public struct Option: Hashable, Sendable, Codable {
        public var name: String
        public var description: String?
    }

    public var kind: Kind
    public var instructions: String
    public var options: [Option]?
    public var levels: [String]?

    public var decisionQuestion: Question {
        switch kind {
        case .binary:
            return .binary(instructions: instructions)
        case .choice:
            return .choice(
                instructions: instructions,
                options: (options ?? []).map {
                    ChoiceOption($0.name, description: $0.description)
                }
            )
        case .score:
            return .score(instructions: instructions, levels: levels ?? [])
        }
    }
}

/// The expected result of a fixture case.
public struct FixtureExpectation: Hashable, Sendable, Codable {
    /// For binary questions, the lowest acceptable probability of "yes".
    public var minimum: Double?
    /// For binary questions, the highest acceptable probability of "yes".
    public var maximum: Double?
    /// For choice questions, the expected option name.
    /// For binary questions, "yes" or "no".
    public var label: String?
    /// For score questions, the expected level index.
    public var level: Int?
    /// A note on why the expectation holds or is debatable.
    public var note: String?
}

/// Where a fixture's labels came from and whether a person reviewed them.
public struct FixtureProvenance: Hashable, Sendable, Codable {
    /// Who or what wrote the items.
    public var source: String
    /// The date the items were written, as YYYY-MM-DD.
    public var created: String
    /// The label review status: "unreviewed" or "reviewed".
    public var reviewStatus: String
    /// The reviewers, if any.
    public var reviewers: [String]?
    /// The date of the review, if any.
    public var reviewed: String?
    public var notes: String?

    public var isReviewed: Bool { reviewStatus == "reviewed" }
}

/// One fixture case: a state, a question, and an expectation.
public struct FixtureCase: Hashable, Sendable, Codable {
    public var id: String
    /// The robustness category, such as `negation`, or `nil` for plain cases.
    public var category: String?
    /// Cases in the same group are compared with each other,
    /// for example the paraphrases of one question.
    public var group: String?
    public var state: String
    public var question: FixtureQuestion
    public var expected: FixtureExpectation?
}

/// A fixture file.
public struct FixtureSet: Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    public var provenance: FixtureProvenance
    public var cases: [FixtureCase]

    public static func load(from url: URL) throws -> FixtureSet {
        let set = try JSONDecoder().decode(FixtureSet.self, from: Data(contentsOf: url))
        var ids = Set<String>()
        for item in set.cases {
            guard ids.insert(item.id).inserted else {
                throw EvaluationError.fixture("Duplicate case id \"\(item.id)\" in \(url.lastPathComponent).")
            }
            // The library validates each question when a session runs it.
        }
        return set
    }
}

/// The result of one fixture case.
public struct FixtureResult: Hashable, Sendable, Codable {
    public var id: String
    public var category: String?
    public var group: String?
    public var kind: FixtureQuestion.Kind
    /// For binary questions, the probability of "yes".
    public var probability: Double?
    /// For choice questions, the selected option. For score questions, the most likely level.
    public var predicted: String?
    /// The option or level probabilities, in question order.
    public var distribution: [Double]
    /// For choice questions, the probability of each option by name.
    public var probabilitiesByName: [String: Double]?
    public var confidence: Double?
    public var expectedScore: Double?
    public var allowedAnswerMass: Double?
    /// Whether the result meets the expectation, or `nil` if there is none.
    public var passed: Bool?
    public var latencySeconds: Double
}

public enum FixtureRunner {
    /// Asks every case's question with a fresh session and checks the expectation.
    public static func run(
        _ set: FixtureSet,
        model: any DecisionModel,
        progress: (FixtureResult) -> Void = { _ in }
    ) async throws -> [FixtureResult] {
        var results: [FixtureResult] = []
        for item in set.cases {
            let session = DecisionSession(model: model, state: .text(item.state))
            let clock = ContinuousClock()
            let started = clock.now
            let response = try await session.decide([item.question.decisionQuestion])
            let latency = (clock.now - started).seconds
            let result = makeResult(
                item,
                answer: response.answers[0],
                diagnostics: response.diagnostics.first,
                latency: latency
            )
            progress(result)
            results.append(result)
        }
        return results
    }

    static func makeResult(
        _ item: FixtureCase,
        answer: Answer,
        diagnostics: DecisionSession.Diagnostics?,
        latency: Double
    ) -> FixtureResult {
        var result = FixtureResult(
            id: item.id,
            category: item.category,
            group: item.group,
            kind: item.question.kind,
            distribution: [],
            allowedAnswerMass: diagnostics?.allowedAnswerMass,
            latencySeconds: latency
        )
        let expected = item.expected

        switch answer {
        case .binary(let p):
            result.probability = p
            result.predicted = p >= 0.5 ? "yes" : "no"
            result.distribution = [p, 1 - p]
            if let expected, expected.minimum != nil || expected.maximum != nil || expected.label != nil {
                var passed = true
                if let minimum = expected.minimum { passed = passed && p >= minimum }
                if let maximum = expected.maximum { passed = passed && p <= maximum }
                if let label = expected.label { passed = passed && result.predicted == label }
                result.passed = passed
            }
        case .choice(let name, let probabilities, let confidence):
            let names = item.question.options?.map(\.name) ?? []
            result.predicted = name
            result.distribution = names.map { probabilities[$0] ?? 0 }
            result.probabilitiesByName = probabilities
            result.confidence = confidence
            if let label = expected?.label {
                result.passed = name == label
            }
        case .score(let value, let probabilities, _, let confidence):
            let best = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
            result.predicted = String(best)
            result.distribution = probabilities
            result.confidence = confidence
            result.expectedScore = value
            if let level = expected?.level {
                result.passed = best == level
            }
        }
        return result
    }
}

// MARK: - Robustness summaries

/// Summary statistics for one robustness category.
public struct RobustnessSummary: Hashable, Sendable, Codable {
    public var category: String
    public var cases: Int
    /// The share of cases with an expectation that met it, or `nil` if no case has one.
    public var passRate: Double?
    /// For grouped categories, the largest disagreement within a group.
    ///
    /// - `option-permutation`: the largest probability change for one option name.
    /// - `paraphrase`: the largest spread of "yes" probabilities.
    /// - `negation`: the largest `|p(q) + p(not q) − 1|`.
    public var worstGroupDisagreement: Double?
    /// For grouped categories, the share of groups whose members agree on the answer.
    /// Negation pairs agree when their answers are opposite.
    public var groupAgreement: Double?
    /// The mean confidence of choice and score answers.
    public var meanConfidence: Double?
    /// The mean allowed-answer mass, for local models.
    public var meanAllowedAnswerMass: Double?

    /// Summarizes results by category.
    public static func summarize(_ results: [FixtureResult]) -> [RobustnessSummary] {
        let byCategory = Dictionary(grouping: results) { $0.category ?? "uncategorized" }
        return byCategory.keys.sorted().map { category in
            summarize(category: category, results: byCategory[category]!)
        }
    }

    static func summarize(category: String, results: [FixtureResult]) -> RobustnessSummary {
        let checked = results.compactMap(\.passed)
        let confidences = results.compactMap(\.confidence)
        let masses = results.compactMap(\.allowedAnswerMass)
        var summary = RobustnessSummary(
            category: category,
            cases: results.count,
            passRate: checked.isEmpty ? nil : Double(checked.filter { $0 }.count) / Double(checked.count),
            meanConfidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            meanAllowedAnswerMass: masses.isEmpty ? nil : masses.reduce(0, +) / Double(masses.count)
        )

        let groups = Dictionary(grouping: results.filter { $0.group != nil }) { $0.group! }.values.filter {
            $0.count > 1
        }
        guard !groups.isEmpty else { return summary }

        var worst = 0.0
        var agreeing = 0
        for members in groups {
            let disagreement: Double
            let agrees: Bool
            switch category {
            case "negation":
                let p = members.compactMap(\.probability)
                disagreement = p.count == 2 ? abs(p[0] + p[1] - 1) : .nan
                agrees = p.count == 2 && (p[0] >= 0.5) != (p[1] >= 0.5)
            default:
                if let first = members.first?.probabilitiesByName {
                    disagreement =
                        first.keys.map { name in
                            let values = members.compactMap { $0.probabilitiesByName?[name] }
                            return (values.max() ?? 0) - (values.min() ?? 0)
                        }.max() ?? 0
                } else {
                    let p = members.compactMap(\.probability)
                    disagreement = (p.max() ?? 0) - (p.min() ?? 0)
                }
                agrees = Set(members.compactMap(\.predicted)).count == 1
            }
            worst = max(worst, disagreement)
            agreeing += agrees ? 1 : 0
        }
        summary.worstGroupDisagreement = worst
        summary.groupAgreement = Double(agreeing) / Double(groups.count)
        return summary
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
