import AnyDecisionModel
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The conditions of an evaluation run, recorded with every report.
public struct RunMetadata: Hashable, Sendable, Codable {
    public var command: String
    public var date: String
    public var hardware: Hardware
    public var operatingSystem: String
    public var model: String
    public var backend: String
    /// The Hugging Face revision of the model files, if known.
    public var modelRevision: String?
    /// The AnyDecisionModel source revision, if given with `--revision`.
    public var libraryRevision: String?
    public var systemPrompt: String?
    public var promptTemplate: String
    public var calibration: Calibration?
    public var prefixCaching: Bool?
    public var rotationDebiasing: Bool?
    public var datasets: [DatasetRecord]
    public var fixtures: [FixtureRecord]

    public struct Hardware: Hashable, Sendable, Codable {
        public var model: String
        public var processor: String
        public var memoryBytes: UInt64
    }

    public struct DatasetRecord: Hashable, Sendable, Codable {
        public var split: DatasetSplit
        public var totalRows: Int
        public var seed: UInt64
        public var role: String
        /// The sampled row indices, so that others can reproduce the sample.
        public var indices: [Int]

        public init(split: DatasetSplit, totalRows: Int, seed: UInt64, role: String, indices: [Int]) {
            self.split = split
            self.totalRows = totalRows
            self.seed = seed
            self.role = role
            self.indices = indices
        }
    }

    public struct FixtureRecord: Hashable, Sendable, Codable {
        public var name: String
        public var cases: Int
        public var provenance: FixtureProvenance

        public init(name: String, cases: Int, provenance: FixtureProvenance) {
            self.name = name
            self.cases = cases
            self.provenance = provenance
        }
    }

    public init(
        command: String,
        model: String,
        backend: String,
        modelRevision: String? = nil,
        libraryRevision: String? = nil,
        systemPrompt: String? = nil,
        calibration: Calibration? = nil,
        prefixCaching: Bool? = nil,
        rotationDebiasing: Bool? = nil
    ) {
        self.command = command
        self.date = ISO8601DateFormatter().string(from: Date())
        self.hardware = SystemInfo.hardware
        self.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        self.model = model
        self.backend = backend
        self.modelRevision = modelRevision
        self.libraryRevision = libraryRevision
        self.systemPrompt = systemPrompt
        self.promptTemplate =
            "Chat template with thinking disabled. "
            + "System: the system prompt. "
            + "User: \"State:\\n<state>\\n\\nQuestion: <instructions>\\n<options or levels>\\n\\nAllowed answers: <labels>\"."
        self.calibration = calibration
        self.prefixCaching = prefixCaching
        self.rotationDebiasing = rotationDebiasing
        self.datasets = []
        self.fixtures = []
    }
}

/// Information about the machine that runs an evaluation.
public enum SystemInfo {
    public static var hardware: RunMetadata.Hardware {
        RunMetadata.Hardware(
            model: sysctlString("hw.model") ?? "unknown",
            processor: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            memoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// The largest physical memory footprint of this process so far, in bytes.
    ///
    /// On Apple silicon this includes GPU buffers in unified memory.
    public static var peakMemoryFootprint: UInt64? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint
        #else
            return nil
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #else
            return nil
        #endif
    }
}

/// Writes JSON and CSV reports.
public struct ReportWriter {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Writes a JSON report and returns its URL.
    @discardableResult
    public func writeJSON<Report: Encodable>(_ report: Report, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        let url = directory.appendingPathComponent("\(name).json")
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    /// Writes a CSV file and returns its URL.
    @discardableResult
    public func writeCSV(header: [String], rows: [[String]], name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = ([header] + rows).map { $0.map(Self.escape).joined(separator: ",") }
        let url = directory.appendingPathComponent("\(name).csv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension Double {
    /// A fixed-precision string for CSV and console output.
    public func formatted(digits: Int) -> String {
        guard isFinite else { return String(self) }
        return String(format: "%.\(digits)f", self)
    }
}
