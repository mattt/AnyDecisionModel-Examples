import Foundation

/// A probabilistic prediction for one labeled item.
public struct Prediction: Hashable, Sendable, Codable {
    /// The probability of each class, in class order.
    public var probabilities: [Double]

    /// The index of the correct class.
    public var label: Int

    /// Whether this is a yes-or-no prediction, with "yes" as class 0.
    public var isBinary: Bool

    /// Creates a prediction.
    public init(probabilities: [Double], label: Int, isBinary: Bool = false) {
        self.probabilities = probabilities
        self.label = label
        self.isBinary = isBinary
    }

    /// Creates a binary prediction from the probability of "yes".
    ///
    /// Class 0 is "yes" and class 1 is "no".
    public init(yesProbability: Double, label: Bool) {
        self.init(probabilities: [yesProbability, 1 - yesProbability], label: label ? 0 : 1, isBinary: true)
    }

    /// The index of the most probable class.
    public var predicted: Int {
        probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
    }

    /// The probability of the most probable class.
    public var confidence: Double {
        probabilities.max() ?? 0
    }

    /// Whether the most probable class is correct.
    public var isCorrect: Bool {
        predicted == label
    }
}

/// Metrics for a set of predictions.
public struct ClassificationMetrics: Hashable, Sendable, Codable {
    public var count: Int
    public var accuracy: Double
    /// Expected calibration error over 10 equal-width confidence bins.
    public var expectedCalibrationError: Double
    /// Mean negative log-likelihood of the correct class.
    public var negativeLogLikelihood: Double
    /// Mean Brier score. See ``Metrics/brierScore(_:)``.
    public var brierScore: Double
    /// Accuracy on the most confident fraction of predictions.
    public var accuracyByCoverage: [CoveragePoint]

    public init(_ predictions: [Prediction], bins: Int = 10) {
        count = predictions.count
        accuracy = Metrics.accuracy(predictions)
        expectedCalibrationError = Metrics.expectedCalibrationError(predictions, bins: bins)
        negativeLogLikelihood = Metrics.negativeLogLikelihood(predictions)
        brierScore = Metrics.brierScore(predictions)
        accuracyByCoverage = Metrics.accuracyByCoverage(predictions)
    }
}

/// Accuracy when only the most confident predictions are kept.
public struct CoveragePoint: Hashable, Sendable, Codable {
    /// The fraction of predictions kept.
    public var coverage: Double
    /// The lowest confidence among the kept predictions.
    public var threshold: Double
    /// The accuracy of the kept predictions.
    public var accuracy: Double
}

/// Metric functions.
public enum Metrics {
    public static func accuracy(_ predictions: [Prediction]) -> Double {
        guard !predictions.isEmpty else { return .nan }
        return Double(predictions.filter(\.isCorrect).count) / Double(predictions.count)
    }

    /// Expected calibration error with equal-width bins over `(b/bins, (b+1)/bins]`.
    public static func expectedCalibrationError(_ predictions: [Prediction], bins: Int = 10) -> Double {
        guard !predictions.isEmpty else { return .nan }
        var total = 0.0
        for bin in 0 ..< bins {
            let lower = Double(bin) / Double(bins)
            let upper = Double(bin + 1) / Double(bins)
            let members = predictions.filter { $0.confidence > lower && $0.confidence <= upper }
            guard !members.isEmpty else { continue }
            let accuracy = Double(members.filter(\.isCorrect).count) / Double(members.count)
            let confidence = members.map(\.confidence).reduce(0, +) / Double(members.count)
            total += Double(members.count) / Double(predictions.count) * abs(accuracy - confidence)
        }
        return total
    }

    public static func negativeLogLikelihood(_ predictions: [Prediction], floor: Double = 1e-12) -> Double {
        guard !predictions.isEmpty else { return .nan }
        let total = predictions.reduce(0.0) { sum, prediction in
            sum - log(max(prediction.probabilities[prediction.label], floor))
        }
        return total / Double(predictions.count)
    }

    /// Mean Brier score.
    ///
    /// Binary predictions use `(p(yes) − y)²`.
    /// Other predictions use the multiclass form, `Σ (p_k − y_k)²`.
    public static func brierScore(_ predictions: [Prediction]) -> Double {
        guard !predictions.isEmpty else { return .nan }
        let total = predictions.reduce(0.0) { sum, prediction in
            if prediction.isBinary {
                let target = prediction.label == 0 ? 1.0 : 0.0
                return sum + (prediction.probabilities[0] - target) * (prediction.probabilities[0] - target)
            }
            return sum
                + prediction.probabilities.enumerated().reduce(0.0) { inner, element in
                    let target = element.offset == prediction.label ? 1.0 : 0.0
                    return inner + (element.element - target) * (element.element - target)
                }
        }
        return total / Double(predictions.count)
    }

    /// Accuracy of the most confident predictions at coverage levels from 10% to 100%.
    public static func accuracyByCoverage(
        _ predictions: [Prediction],
        levels: [Double] = stride(from: 0.1, through: 1.0001, by: 0.1).map { $0 }
    ) -> [CoveragePoint] {
        guard !predictions.isEmpty else { return [] }
        let sorted = predictions.sorted { $0.confidence > $1.confidence }
        return levels.map { level in
            let kept = max(1, Int((level * Double(sorted.count) - 1e-9).rounded(.up)))
            let slice = sorted.prefix(min(kept, sorted.count))
            return CoveragePoint(
                coverage: min(level, 1),
                threshold: slice.last?.confidence ?? 0,
                accuracy: accuracy(Array(slice))
            )
        }
    }

    /// Mean absolute difference between expected level and labeled level.
    public static func ordinalError(expected: [Double], labels: [Int]) -> Double {
        guard !labels.isEmpty else { return .nan }
        return zip(expected, labels).reduce(0.0) { $0 + abs($1.0 - Double($1.1)) } / Double(labels.count)
    }

    /// Returns the value at quantile `q` with linear interpolation.
    public static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
