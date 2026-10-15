import AnyDecisionModel
import Foundation
import Testing

@testable import DecisionEvaluation

@Suite("Metrics")
struct MetricsTests {
    @Test func accuracyAndCalibrationError() {
        let predictions = [
            Prediction(yesProbability: 0.9, label: true),
            Prediction(yesProbability: 0.8, label: false),
            Prediction(yesProbability: 0.3, label: false),
            Prediction(yesProbability: 0.45, label: true),
        ]
        #expect(Metrics.accuracy(predictions) == 0.5)
        // Bins: 0.9 (correct), 0.8 (wrong), 0.7 (correct), 0.55 (wrong).
        let expected = 0.25 * abs(1 - 0.9) + 0.25 * abs(0 - 0.8) + 0.25 * abs(1 - 0.7) + 0.25 * abs(0 - 0.55)
        #expect(abs(Metrics.expectedCalibrationError(predictions) - expected) < 1e-12)
    }

    @Test func negativeLogLikelihoodAndBrier() {
        let binary = [Prediction(yesProbability: 0.8, label: true), Prediction(yesProbability: 0.8, label: false)]
        #expect(abs(Metrics.negativeLogLikelihood(binary) - (-(log(0.8) + log(0.2)) / 2)) < 1e-12)
        #expect(abs(Metrics.brierScore(binary) - (0.04 + 0.64) / 2) < 1e-12)

        let multiclass = [Prediction(probabilities: [0.5, 0.3, 0.2], label: 1)]
        #expect(abs(Metrics.brierScore(multiclass) - (0.25 + 0.49 + 0.04)) < 1e-12)
    }

    @Test func accuracyByCoverageKeepsMostConfident() {
        let predictions = [
            Prediction(probabilities: [0.99, 0.01], label: 0),
            Prediction(probabilities: [0.9, 0.1], label: 0),
            Prediction(probabilities: [0.6, 0.4], label: 1),
            Prediction(probabilities: [0.55, 0.45], label: 1),
        ]
        let curve = Metrics.accuracyByCoverage(predictions, levels: [0.5, 1.0])
        #expect(curve[0].accuracy == 1)
        #expect(curve[0].threshold == 0.9)
        #expect(curve[1].accuracy == 0.5)
    }

    @Test func coverageLevelsDoNotRoundUpFromFloatingPointError() {
        let predictions = (0 ..< 10).map {
            Prediction(probabilities: [1 - Double($0) / 100, Double($0) / 100], label: $0 < 3 ? 0 : 1)
        }
        let curve = Metrics.accuracyByCoverage(predictions, levels: [0.3])
        #expect(curve[0].accuracy == 1)
    }

    @Test func ordinalErrorAndQuantiles() {
        #expect(Metrics.ordinalError(expected: [1.5, 0.2], labels: [2, 0]) == 0.35)
        #expect(Metrics.quantile([1, 2, 3, 4, 5], 0.5) == 3)
        #expect(Metrics.quantile([1, 2, 3, 4, 5], 0.95) == 4.8)
    }
}

@Suite("Sampling")
struct SamplingTests {
    @Test func permutationIsDeterministicAndComplete() {
        let a = Sampling.permutation(count: 100, seed: 0)
        let b = Sampling.permutation(count: 100, seed: 0)
        #expect(a == b)
        #expect(Set(a) == Set(0 ..< 100))
        #expect(a != Sampling.permutation(count: 100, seed: 1))
    }

    @Test func knownSequence() {
        // Pin the sequence so that a change to the generator is caught.
        #expect(Sampling.sample(5, from: 3270, seed: 0) == Sampling.sample(5, from: 3270, seed: 0))
        var generator = SeededGenerator(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    }

    @Test func splitIsDisjoint() {
        let split = Sampling.split(fit: 200, test: 200, from: 3270, seed: 1)
        #expect(split.fit.count == 200)
        #expect(split.test.count == 200)
        #expect(Set(split.fit).isDisjoint(with: split.test))
    }
}

@Suite("Calibration fitting")
struct CalibrationFittingTests {
    /// Returns `1 / (1 + exp(-x))`, used here to build synthetic predictions.
    private func sigmoid(_ x: Double) -> Double {
        1 / (1 + exp(-x))
    }

    @Test func recoversTemperatureFromOverconfidentPredictions() {
        // True probabilities are 0.75 and 0.25,
        // but the raw model reports sigmoid(4 · logit(p)): the right temperature is 4.
        var generator = SeededGenerator(seed: 7)
        let trueLogit = log(0.75 / 0.25)
        let predictions = (0 ..< 2000).map { index in
            let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
            let truth = sigmoid(sign * trueLogit)
            let label = Double(generator.next() % 10_000) / 10_000 < truth
            return Prediction(yesProbability: sigmoid(sign * 4 * trueLogit), label: label)
        }
        let calibration = CalibrationFitting.fit(binary: predictions)
        #expect(calibration.temperature >= 3 && calibration.temperature <= 5.5)
        #expect(abs(calibration.binaryBias) <= 0.25)

        let before = Metrics.negativeLogLikelihood(predictions)
        let after = Metrics.negativeLogLikelihood(predictions.map { CalibrationFitting.apply(calibration, to: $0) })
        #expect(after < before)
    }

    @Test func biasDoesNotApplyToMulticlass() {
        let prediction = Prediction(probabilities: [0.5, 0.5], label: 0)
        let calibrated = CalibrationFitting.apply(Calibration(temperature: 1, binaryBias: 2), to: prediction)
        #expect(calibrated.probabilities == [0.5, 0.5])
    }
}

@Suite("Fixtures")
struct FixtureTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/decision-eval/Fixtures")

    @Test(arguments: ["sanity", "routing", "robustness"])
    func fixturesLoadAndValidate(name: String) throws {
        let set = try FixtureSet.load(from: Self.directory.appendingPathComponent("\(name).json"))
        #expect(set.name == name)
        #expect(!set.cases.isEmpty)
        for item in set.cases where item.question.kind == .choice {
            if let label = item.expected?.label {
                #expect(item.question.options?.contains { $0.name == label } == true, "\(item.id)")
            }
        }
    }

    @Test func sanityHasNineCases() throws {
        let set = try FixtureSet.load(from: Self.directory.appendingPathComponent("sanity.json"))
        #expect(set.cases.count == 9)
    }

    @Test func unreviewedLabelsAreMarked() throws {
        let routing = try FixtureSet.load(from: Self.directory.appendingPathComponent("routing.json"))
        #expect(!routing.provenance.isReviewed)
    }

    @Test func robustnessSummaryMeasuresGroups() {
        func result(_ id: String, _ category: String, _ group: String, p: Double) -> FixtureResult {
            FixtureResult(
                id: id,
                category: category,
                group: group,
                kind: .binary,
                probability: p,
                predicted: p >= 0.5 ? "yes" : "no",
                distribution: [p, 1 - p],
                latencySeconds: 0
            )
        }
        let summaries = RobustnessSummary.summarize([
            result("a", "negation", "g", p: 0.9),
            result("b", "negation", "g", p: 0.2),
            result("c", "paraphrase", "h", p: 0.7),
            result("d", "paraphrase", "h", p: 0.4),
        ])
        let negation = summaries.first { $0.category == "negation" }!
        #expect(abs(negation.worstGroupDisagreement! - 0.1) < 1e-12)
        #expect(negation.groupAgreement == 1)
        let paraphrase = summaries.first { $0.category == "paraphrase" }!
        #expect(abs(paraphrase.worstGroupDisagreement! - 0.3) < 1e-12)
        #expect(paraphrase.groupAgreement == 0)
    }
}

@Suite("Reports")
struct ReportTests {
    @Test func csvEscapesFields() {
        #expect(ReportWriter.escape("plain") == "plain")
        #expect(ReportWriter.escape("a,b") == "\"a,b\"")
        #expect(ReportWriter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }
}
