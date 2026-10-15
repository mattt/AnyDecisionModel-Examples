import AnyDecisionModel
import Foundation

/// Fits a ``Calibration`` to raw predictions by grid search on negative log-likelihood.
///
/// The fit uses raw (uncalibrated) probabilities.
/// Binary and choice predictions share one temperature;
/// the bias applies to binary predictions only, as in ``Calibration``.
public enum CalibrationFitting {
    /// Temperatures from 0.5 to 19.75 in steps of 0.25.
    static let temperatureGrid = (2 ..< 80).map { Double($0) / 4 }

    /// Biases from −3 to 3 in steps of 0.25.
    static let biasGrid = (-12 ... 12).map { Double($0) / 4 }

    /// The floor applied to raw probabilities before taking logarithms.
    ///
    /// Raw probabilities of exactly 0 or 1 have no finite log-odds.
    static let probabilityFloor = 1e-9

    /// Returns the calibration with the lowest mean negative log-likelihood.
    ///
    /// - Parameters:
    ///   - binary: Raw binary predictions (class 0 is "yes").
    ///   - multiclass: Raw choice or score predictions.
    public static func fit(binary: [Prediction], multiclass: [Prediction] = []) -> Calibration {
        let biases = binary.isEmpty ? [0.0] : biasGrid
        var best = Calibration.identity
        var bestLoss = Double.infinity
        for temperature in temperatureGrid {
            for bias in biases {
                let calibration = Calibration(temperature: temperature, binaryBias: bias)
                let loss = negativeLogLikelihood(binary: binary, multiclass: multiclass, calibration: calibration)
                if loss < bestLoss {
                    bestLoss = loss
                    best = calibration
                }
            }
        }
        return best
    }

    /// Applies a calibration to a raw prediction.
    public static func apply(_ calibration: Calibration, to prediction: Prediction) -> Prediction {
        let logs = prediction.probabilities.map { log(min(max($0, probabilityFloor), 1)) }
        let probabilities = calibration.probabilities(logMasses: logs, binary: prediction.isBinary)
        return Prediction(probabilities: probabilities, label: prediction.label, isBinary: prediction.isBinary)
    }

    static func negativeLogLikelihood(binary: [Prediction], multiclass: [Prediction], calibration: Calibration)
        -> Double
    {
        let all = binary.map { apply(calibration, to: $0) } + multiclass.map { apply(calibration, to: $0) }
        return Metrics.negativeLogLikelihood(all)
    }
}
