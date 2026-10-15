import AnyDecisionModel
import DecisionEvaluation
import Foundation

let defaultModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

let usage = """
    Usage: decision-eval <command> [options]

    Commands:
      sanity        Run the nine sanity cases.
      routing       Run the support-ticket routing fixtures and the fallback report.
      robustness    Run the robustness probes.
      boolq         Evaluate BoolQ (binary). Options: --n 200 --seed 0
      agnews        Evaluate AG News (choice). Options: --n 200 --seed 0
      calibrate     Fit a calibration on one sample and report on another.
                    Options: --fit 200 --test 200 --seed 1 --tasks boolq,agnews
      latency       Measure cold loading and warm batch latency.
                    Options: --batches 1,8,32 --repetitions 10

    Model options:
      --model <id>              Hugging Face model ID (default: \(defaultModelID))
      --model-directory <path>  Load model files from a local directory.
      --calibration <file>      Apply a calibration JSON file written by `calibrate`.
      --debias                  Average choice results over option rotations.
      --prefix-cache            Enable the session prefix cache after validating it.

    Report options:
      --out <dir>               Report directory (default: reports).
      --revision <text>         AnyDecisionModel source revision to record.
      --model-revision <text>   Model file revision to record.
      --threshold <p>           Routing confidence threshold (default: 0.5).
      --require-reviewed        Fail if fixture labels have not been reviewed.
    """

struct Options {
    var command = ""
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        var remaining = arguments[...]
        guard let command = remaining.popFirst(), !command.hasPrefix("-") else {
            throw EvaluationError.usage(usage)
        }
        self.command = command
        let flagNames: Set<String> = ["debias", "prefix-cache", "require-reviewed", "help"]
        while let argument = remaining.popFirst() {
            guard argument.hasPrefix("--") else {
                throw EvaluationError.usage("Unexpected argument \(argument).\n\n\(usage)")
            }
            let name = String(argument.dropFirst(2))
            if flagNames.contains(name) {
                flags.insert(name)
            } else if let value = remaining.popFirst() {
                values[name] = value
            } else {
                throw EvaluationError.usage("Missing value for \(argument).")
            }
        }
    }

    func int(_ name: String, default value: Int) throws -> Int {
        guard let text = values[name] else { return value }
        guard let number = Int(text), number >= 0 else {
            throw EvaluationError.usage("--\(name) needs a non-negative integer.")
        }
        return number
    }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let text = values[name] else { return value }
        guard let number = Double(text) else { throw EvaluationError.usage("--\(name) needs a number.") }
        return number
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fixture(_ name: String) throws -> FixtureSet {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw EvaluationError.fixture("Missing fixture \(name).json.")
    }
    return try FixtureSet.load(from: url)
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

func line(_ metrics: ClassificationMetrics) -> String {
    "n=\(metrics.count) acc=\(metrics.accuracy.formatted(digits: 3)) ECE=\(metrics.expectedCalibrationError.formatted(digits: 3)) "
        + "NLL=\(metrics.negativeLogLikelihood.formatted(digits: 3)) Brier=\(metrics.brierScore.formatted(digits: 3))"
}

// MARK: - Reports

struct FixtureReport: Encodable {
    var metadata: RunMetadata
    var results: [FixtureResult]
    var passRate: Double?
    var summaries: [RobustnessSummary]?
    var routing: RoutingSummary?
}

struct RoutingSummary: Encodable {
    var threshold: Double
    var metrics: ClassificationMetrics
    /// The share of tickets routed without a person.
    var automatedShare: Double
    /// The accuracy of the tickets routed without a person.
    var automatedAccuracy: Double
    /// The tickets sent to a person because confidence was below the threshold.
    var deferred: [String]
    var policy: String
}

struct BenchmarkReport: Encodable {
    var metadata: RunMetadata
    var metrics: ClassificationMetrics
    var meanAllowedAnswerMass: Double?
    var p50LatencySeconds: Double
    var p95LatencySeconds: Double
    var items: [BenchmarkItem]
}

struct CalibrationReport: Encodable {
    var metadata: RunMetadata
    var calibration: Calibration
    var heldOut: [String: [String: ClassificationMetrics]]
}

struct LatencyReport: Encodable {
    var metadata: RunMetadata
    var coldLoadSeconds: Double
    var firstQuestionSeconds: Double
    var warm: [LatencyResult]
    var peakMemoryFootprintBytes: UInt64?
}

func fixtureRows(_ results: [FixtureResult]) -> [[String]] {
    results.map { result in
        [
            result.id, result.category ?? "", result.group ?? "", result.kind.rawValue,
            result.probability.map { $0.formatted(digits: 6) } ?? "",
            result.predicted ?? "",
            result.distribution.map { $0.formatted(digits: 6) }.joined(separator: " "),
            result.confidence.map { $0.formatted(digits: 4) } ?? "",
            result.allowedAnswerMass.map { $0.formatted(digits: 4) } ?? "",
            result.passed.map(String.init) ?? "",
            result.latencySeconds.formatted(digits: 4),
        ]
    }
}

let fixtureHeader = [
    "id", "category", "group", "kind", "probability", "predicted", "distribution",
    "confidence", "allowed_answer_mass", "passed", "latency_seconds",
]

func benchmarkRows(_ items: [BenchmarkItem]) -> [[String]] {
    items.map { item in
        [
            String(item.row), String(item.prediction.label), String(item.prediction.predicted),
            item.prediction.probabilities.map { $0.formatted(digits: 6) }.joined(separator: " "),
            item.allowedAnswerMass.map { $0.formatted(digits: 4) } ?? "",
            item.latencySeconds.formatted(digits: 4),
        ]
    }
}

let benchmarkHeader = ["row", "label", "predicted", "probabilities", "allowed_answer_mass", "latency_seconds"]

// MARK: - Main

@main
struct DecisionEval {
    static func main() async {
        do {
            try await run(Options(Array(CommandLine.arguments.dropFirst())))
        } catch let error as EvaluationError {
            log(error.description)
            exit(2)
        } catch {
            log("Error: \(error)")
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        if options.flags.contains("help") || options.command == "help" {
            print(usage)
            exit(0)
        }

        var model = MLXDecisionModel(
            modelID: options.values["model"] ?? defaultModelID,
            directory: options.values["model-directory"].map { URL(fileURLWithPath: $0) },
            rotationDebiasing: options.flags.contains("debias"),
            prefixCaching: options.flags.contains("prefix-cache")
        )
        if let path = options.values["calibration"] {
            model.calibration = try JSONDecoder().decode(
                Calibration.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
        }

        func metadata(_ command: String) -> RunMetadata {
            RunMetadata(
                command: command,
                model: model.modelID,
                backend: "mlx",
                modelRevision: options.values["model-revision"],
                libraryRevision: options.values["revision"],
                systemPrompt: model.systemPrompt,
                calibration: model.calibration,
                prefixCaching: model.prefixCaching,
                rotationDebiasing: model.rotationDebiasing
            )
        }

        let writer = ReportWriter(directory: URL(fileURLWithPath: options.values["out"] ?? "reports"))
        let name = "\(options.command)-\(timestamp())"
        let datasets = DatasetClient()

        switch options.command {
        case "sanity", "routing", "robustness":
            let set = try fixture(options.command)
            if options.flags.contains("require-reviewed"), !set.provenance.isReviewed {
                throw EvaluationError.fixture(
                    "The \(set.name) labels are \(set.provenance.reviewStatus). A person must review them first."
                )
            }
            if !set.provenance.isReviewed {
                log(
                    "Note: the \(set.name) labels are \(set.provenance.reviewStatus). Do not publish these results as reviewed."
                )
            }
            var meta = metadata(options.command)
            meta.fixtures = [.init(name: set.name, cases: set.cases.count, provenance: set.provenance)]

            let results = try await FixtureRunner.run(set, model: model) { result in
                let value = result.probability.map { $0.formatted(digits: 4) } ?? (result.predicted ?? "")
                let status = result.passed.map { $0 ? "pass" : "FAIL" } ?? "-"
                print(
                    "  \(result.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(status.padding(toLength: 5, withPad: " ", startingAt: 0)) \(value) \(result.distribution.map { $0.formatted(digits: 3) })"
                )
            }
            let checked = results.compactMap(\.passed)
            var report = FixtureReport(
                metadata: meta,
                results: results,
                passRate: checked.isEmpty ? nil : Double(checked.filter { $0 }.count) / Double(checked.count)
            )

            if options.command == "robustness" {
                report.summaries = RobustnessSummary.summarize(results)
                for summary in report.summaries! {
                    print(
                        "  \(summary.category): cases=\(summary.cases) pass=\(summary.passRate.map { $0.formatted(digits: 2) } ?? "-") "
                            + "worst-disagreement=\(summary.worstGroupDisagreement.map { $0.formatted(digits: 3) } ?? "-") "
                            + "agreement=\(summary.groupAgreement.map { $0.formatted(digits: 2) } ?? "-")"
                    )
                }
            }

            if options.command == "routing" {
                let threshold = try options.double("threshold", default: 0.5)
                let predictions = zip(set.cases, results).map { item, result in
                    let names = item.question.options?.map(\.name) ?? []
                    return Prediction(
                        probabilities: result.distribution,
                        label: names.firstIndex(of: item.expected?.label ?? "") ?? 0
                    )
                }
                let automated = zip(results, predictions).filter { ($0.0.confidence ?? 0) >= threshold }
                report.routing = RoutingSummary(
                    threshold: threshold,
                    metrics: ClassificationMetrics(predictions),
                    automatedShare: Double(automated.count) / Double(max(results.count, 1)),
                    automatedAccuracy: Metrics.accuracy(automated.map(\.1)),
                    deferred: results.filter { ($0.confidence ?? 0) < threshold }.map(\.id),
                    policy: "Tickets below the confidence threshold go to a person. Nothing is sent to a cloud model."
                )
                print("  \(line(report.routing!.metrics))")
                print(
                    "  automated \(report.routing!.automatedShare.formatted(digits: 2)) at acc \(report.routing!.automatedAccuracy.formatted(digits: 3)); deferred to a person: \(report.routing!.deferred)"
                )
            }

            print("  pass rate: \(report.passRate.map { $0.formatted(digits: 3) } ?? "-")")
            try writer.writeJSON(report, name: name)
            try writer.writeCSV(header: fixtureHeader, rows: fixtureRows(results), name: name)

        case "boolq", "agnews":
            let n = try options.int("n", default: 200)
            let seed = UInt64(try options.int("seed", default: 0))
            var meta = metadata(options.command)
            let items: [BenchmarkItem]
            if options.command == "boolq" {
                let rows = try await datasets.rows(.boolQ, as: BoolQItem.self)
                let indices = Sampling.sample(n, from: rows.count, seed: seed)
                meta.datasets = [
                    .init(split: .boolQ, totalRows: rows.count, seed: seed, role: "evaluation", indices: indices)
                ]
                items = try await Benchmarks.boolQ(rows, indices: indices, model: model) {
                    if $0 % 25 == 0 { log("  \($0)/\(n)") }
                }
            } else {
                let rows = try await datasets.rows(.agNews, as: AGNewsItem.self)
                let indices = Sampling.sample(n, from: rows.count, seed: seed)
                meta.datasets = [
                    .init(split: .agNews, totalRows: rows.count, seed: seed, role: "evaluation", indices: indices)
                ]
                items = try await Benchmarks.agNews(rows, indices: indices, model: model) {
                    if $0 % 25 == 0 { log("  \($0)/\(n)") }
                }
            }
            let latencies = items.map(\.latencySeconds)
            let masses = items.compactMap(\.allowedAnswerMass)
            let report = BenchmarkReport(
                metadata: meta,
                metrics: ClassificationMetrics(items.map(\.prediction)),
                meanAllowedAnswerMass: masses.isEmpty ? nil : masses.reduce(0, +) / Double(masses.count),
                p50LatencySeconds: Metrics.quantile(latencies, 0.5),
                p95LatencySeconds: Metrics.quantile(latencies, 0.95),
                items: items
            )
            print(
                "  \(options.command) \(line(report.metrics)) p50=\((report.p50LatencySeconds * 1000).formatted(digits: 0)) ms"
            )
            try writer.writeJSON(report, name: name)
            try writer.writeCSV(header: benchmarkHeader, rows: benchmarkRows(items), name: name)

        case "calibrate":
            guard model.calibration == nil else {
                throw EvaluationError.usage("calibrate fits raw probabilities. Remove --calibration.")
            }
            let fitCount = try options.int("fit", default: 200)
            let testCount = try options.int("test", default: 200)
            let seed = UInt64(try options.int("seed", default: 1))
            let tasks = Set((options.values["tasks"] ?? "boolq,agnews").split(separator: ",").map(String.init))
            var meta = metadata("calibrate")

            var fitBinary: [Prediction] = []
            var fitChoice: [Prediction] = []
            var test: [String: [Prediction]] = [:]

            if tasks.contains("boolq") {
                let rows = try await datasets.rows(.boolQ, as: BoolQItem.self)
                let split = Sampling.split(fit: fitCount, test: testCount, from: rows.count, seed: seed)
                meta.datasets += [
                    .init(split: .boolQ, totalRows: rows.count, seed: seed, role: "fit", indices: split.fit),
                    .init(split: .boolQ, totalRows: rows.count, seed: seed, role: "test", indices: split.test),
                ]
                log("BoolQ fit")
                fitBinary = try await Benchmarks.boolQ(rows, indices: split.fit, model: model).map(\.prediction)
                log("BoolQ test")
                test["boolq"] = try await Benchmarks.boolQ(rows, indices: split.test, model: model).map(\.prediction)
            }
            if tasks.contains("agnews") {
                let rows = try await datasets.rows(.agNews, as: AGNewsItem.self)
                let split = Sampling.split(fit: fitCount, test: testCount, from: rows.count, seed: seed)
                meta.datasets += [
                    .init(split: .agNews, totalRows: rows.count, seed: seed, role: "fit", indices: split.fit),
                    .init(split: .agNews, totalRows: rows.count, seed: seed, role: "test", indices: split.test),
                ]
                log("AG News fit")
                fitChoice = try await Benchmarks.agNews(rows, indices: split.fit, model: model).map(\.prediction)
                log("AG News test")
                test["agnews"] = try await Benchmarks.agNews(rows, indices: split.test, model: model).map(\.prediction)
            }

            let calibration = CalibrationFitting.fit(binary: fitBinary, multiclass: fitChoice)
            print("  fitted temperature=\(calibration.temperature) binaryBias=\(calibration.binaryBias)")
            var heldOut: [String: [String: ClassificationMetrics]] = [:]
            for (task, predictions) in test.sorted(by: { $0.key < $1.key }) {
                let raw = ClassificationMetrics(predictions)
                let calibrated = ClassificationMetrics(
                    predictions.map { CalibrationFitting.apply(calibration, to: $0) }
                )
                heldOut[task] = ["raw": raw, "calibrated": calibrated]
                print("  \(task) raw        \(line(raw))")
                print("  \(task) calibrated \(line(calibrated))")
            }
            let report = CalibrationReport(metadata: meta, calibration: calibration, heldOut: heldOut)
            try writer.writeJSON(report, name: name)
            try writer.writeJSON(calibration, name: "\(name)-calibration")

        case "latency":
            let batchSizes = (options.values["batches"] ?? "1,8,32").split(separator: ",").compactMap { Int($0) }
            let repetitions = try options.int("repetitions", default: 10)

            // Make sure the files are downloaded, then measure a load from disk.
            log("Downloading and loading once")
            try await DecisionSession(model: model, state: "warm up").prewarm()
            model.removeFromCache()
            let coldSession = DecisionSession(model: model, state: "A 6 sided die rolled a 3.")
            let (_, coldLoad) = try await Benchmarks.timed { try await coldSession.prewarm() }
            let (_, firstQuestion) = try await Benchmarks.timed {
                try await coldSession.probability(of: "Is the number rolled odd?")
            }
            print(
                "  cold load \(coldLoad.formatted(digits: 2)) s, first question \((firstQuestion * 1000).formatted(digits: 0)) ms"
            )

            let short = "I was charged twice this month and nobody has answered my emails in a week. Fix this NOW."
            let paragraph =
                "The customer reports that the invoice for the annual plan was issued twice, "
                + "once on the first of the month and again after a failed card update. "
                + "Support replied with a template, and the customer followed up three times without an answer. "
            let long = String(repeating: paragraph, count: 24) + short
            let results = try await LatencyBenchmark.run(
                model: model,
                states: [("short", short), ("long", long)],
                batchSizes: batchSizes,
                repetitions: repetitions
            ) { result in
                print(
                    "  \(result.state) batch=\(result.batchSize) tokens/question=\(result.promptTokensPerQuestion.formatted(digits: 0)) "
                        + "p50=\((result.p50 * 1000).formatted(digits: 0)) ms p95=\((result.p95 * 1000).formatted(digits: 0)) ms "
                        + "per question=\((result.p50PerQuestion * 1000).formatted(digits: 0)) ms"
                )
            }
            let report = LatencyReport(
                metadata: metadata("latency"),
                coldLoadSeconds: coldLoad,
                firstQuestionSeconds: firstQuestion,
                warm: results,
                peakMemoryFootprintBytes: SystemInfo.peakMemoryFootprint
            )
            if let peak = report.peakMemoryFootprintBytes {
                print("  peak memory footprint \(Double(peak) / 1_073_741_824) GiB")
            }
            try writer.writeJSON(report, name: name)
            try writer.writeCSV(
                header: [
                    "state", "state_characters", "prompt_tokens_per_question", "batch_size", "repetitions", "p50_s",
                    "p95_s", "mean_s",
                ],
                rows: results.map {
                    [
                        $0.state, String($0.stateCharacters), $0.promptTokensPerQuestion.formatted(digits: 1),
                        String($0.batchSize), String($0.repetitions),
                        $0.p50.formatted(digits: 4), $0.p95.formatted(digits: 4), $0.mean.formatted(digits: 4),
                    ]
                },
                name: name
            )

        default:
            throw EvaluationError.usage("Unknown command \(options.command).\n\n\(usage)")
        }
        log("Wrote \(writer.directory.path)/\(name).json")
    }
}
