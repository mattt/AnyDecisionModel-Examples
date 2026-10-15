import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A Hugging Face dataset split.
public struct DatasetSplit: Hashable, Sendable, Codable {
    public var dataset: String
    public var config: String
    public var split: String

    public init(dataset: String, config: String = "default", split: String) {
        self.dataset = dataset
        self.config = config
        self.split = split
    }

    /// The BoolQ validation split (3,270 yes-or-no questions about passages).
    public static let boolQ = DatasetSplit(dataset: "google/boolq", split: "validation")

    /// The AG News test split (7,600 news articles in four topics).
    public static let agNews = DatasetSplit(dataset: "fancyzhx/ag_news", split: "test")

    var cacheName: String {
        "\(dataset.replacingOccurrences(of: "/", with: "--"))--\(config)--\(split).json"
    }
}

/// One BoolQ item.
public struct BoolQItem: Hashable, Sendable, Codable {
    public var question: String
    public var passage: String
    public var answer: Bool
}

/// One AG News item.
public struct AGNewsItem: Hashable, Sendable, Codable {
    public var text: String
    /// The topic index: 0 world, 1 sports, 2 business, 3 science and technology.
    public var label: Int
}

/// Downloads dataset splits from the Hugging Face dataset viewer API and caches them on disk.
///
/// The API returns at most 100 rows per request.
/// A full split is downloaded once and read from the cache after that.
public struct DatasetClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://datasets-server.huggingface.co")!

    public var endpoint: URL
    public var cacheDirectory: URL
    public var session: URLSession
    public var pageSize = 100

    public init(
        endpoint: URL = defaultEndpoint,
        cacheDirectory: URL = DatasetClient.defaultCacheDirectory,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    /// `~/Library/Caches/AnyDecisionModel/datasets` on macOS.
    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnyDecisionModel")
            .appendingPathComponent("datasets")
    }

    /// Returns every row of a split, downloading it if it is not cached.
    public func rows<Row: Codable & Sendable>(_ split: DatasetSplit, as type: Row.Type) async throws -> [Row] {
        let file = cacheDirectory.appendingPathComponent(split.cacheName)
        if let data = try? Data(contentsOf: file) {
            return try JSONDecoder().decode([Row].self, from: data)
        }

        var rows: [Row] = []
        var total = Int.max
        while rows.count < total {
            try Task.checkCancellation()
            let page: Page<Row> = try await fetchPage(split, offset: rows.count)
            total = page.numRowsTotal
            guard !page.rows.isEmpty else { break }
            rows.append(contentsOf: page.rows.sorted { $0.rowIdx < $1.rowIdx }.map(\.row))
        }
        guard rows.count == total else {
            throw EvaluationError.dataset("Expected \(total) rows for \(split.dataset), got \(rows.count).")
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(rows).write(to: file, options: .atomic)
        return rows
    }

    private struct Page<Row: Decodable>: Decodable {
        struct Entry: Decodable {
            let rowIdx: Int
            let row: Row

            enum CodingKeys: String, CodingKey {
                case rowIdx = "row_idx"
                case row
            }
        }

        let rows: [Entry]
        let numRowsTotal: Int

        enum CodingKeys: String, CodingKey {
            case rows
            case numRowsTotal = "num_rows_total"
        }
    }

    private func fetchPage<Row: Decodable>(_ split: DatasetSplit, offset: Int) async throws -> Page<Row> {
        var components = URLComponents(url: endpoint.appendingPathComponent("rows"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "dataset", value: split.dataset),
            URLQueryItem(name: "config", value: split.config),
            URLQueryItem(name: "split", value: split.split),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "length", value: String(pageSize)),
        ]

        var attempt = 0
        while true {
            let (data, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try JSONDecoder().decode(Page<Row>.self, from: data)
            }
            // The dataset viewer rate-limits bursts. Back off, honoring Retry-After, and retry.
            guard status == 429 || status >= 500, attempt < 8 else {
                let detail = String(decoding: data.prefix(200), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                throw EvaluationError.dataset("HTTP \(status) for \(split.dataset) at offset \(offset): \(detail)")
            }
            attempt += 1
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(
                Double.init
            )
            let delay = min(retryAfter ?? pow(2, Double(attempt)), 60)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

public enum EvaluationError: Error, CustomStringConvertible {
    case dataset(String)
    case fixture(String)
    case usage(String)

    public var description: String {
        switch self {
        case .dataset(let detail): return "Dataset error: \(detail)"
        case .fixture(let detail): return "Fixture error: \(detail)"
        case .usage(let detail): return detail
        }
    }
}

// MARK: - Sampling

/// A deterministic pseudo-random generator (SplitMix64).
///
/// The same seed gives the same sequence on every platform and Swift version,
/// unlike `SystemRandomNumberGenerator`.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public enum Sampling {
    /// Returns a deterministic permutation of `0..<count`.
    ///
    /// This uses a Fisher-Yates shuffle with explicit bounded draws,
    /// so the result does not depend on the standard library's shuffle algorithm.
    public static func permutation(count: Int, seed: UInt64) -> [Int] {
        var generator = SeededGenerator(seed: seed)
        var indices = Array(0 ..< count)
        guard count > 1 else { return indices }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int(bounded(UInt64(i + 1), using: &generator))
            indices.swapAt(i, j)
        }
        return indices
    }

    /// Returns `n` deterministic sample indices from `0..<count`.
    public static func sample(_ n: Int, from count: Int, seed: UInt64) -> [Int] {
        Array(permutation(count: count, seed: seed).prefix(n))
    }

    /// Returns two disjoint deterministic samples, for calibration fitting and testing.
    public static func split(fit: Int, test: Int, from count: Int, seed: UInt64) -> (fit: [Int], test: [Int]) {
        let order = permutation(count: count, seed: seed)
        return (Array(order.prefix(fit)), Array(order.dropFirst(fit).prefix(test)))
    }

    /// Returns a uniform value in `0..<upperBound` without modulo bias.
    static func bounded(_ upperBound: UInt64, using generator: inout SeededGenerator) -> UInt64 {
        let threshold = (0 &- upperBound) % upperBound
        while true {
            let value = generator.next()
            if value >= threshold {
                return value % upperBound
            }
        }
    }
}
