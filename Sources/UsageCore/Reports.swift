import Foundation

public struct TokenTotals: Encodable, Equatable, Sendable {
    public var replies: Int64 = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var cacheRead: Int64 = 0

    public init() {}

    public var total: Int64 { input + output + cacheWrite + cacheRead }

    private enum CodingKeys: String, CodingKey {
        case replies, input, output, cacheWrite, cacheRead, total
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(replies, forKey: .replies)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(cacheWrite, forKey: .cacheWrite)
        try c.encode(cacheRead, forKey: .cacheRead)
        try c.encode(total, forKey: .total)
    }
}

public struct ReportRow: Encodable, Equatable, Sendable {
    public var label: String
    public var totals: TokenTotals
    /// At API list prices. Nil when none of these replies has a known price.
    public var costUSD: Double?

    public init(label: String, totals: TokenTotals, costUSD: Double? = nil) {
        self.label = label
        self.totals = totals
        self.costUSD = costUSD
    }
}

public enum Grouping: String, CaseIterable, Sendable {
    case day, project, model, source
}

extension UsageStore {
    /// Totals for everything from `since` onward. A nil date means all of history.
    public func totals(since: Date? = nil) throws -> TokenTotals {
        try rows(selecting: "'all'", since: since).first?.totals ?? TokenTotals()
    }

    /// What logged use from `since` until `until` would cost at API list prices.
    public func cost(since: Date? = nil, until: Date? = nil) throws -> CostSummary {
        try costs(selecting: "'all'", since: since, until: until)["all"] ?? CostSummary()
    }

    /// Prices depend on the model, speed and prompt length, so tokens are added up within each of
    /// those before being priced. A cache write with no recorded lifetime counts as 1 hour, which
    /// is what Claude Code used when the logs didn't record it.
    private func costs(selecting key: String, since: Date?, until: Date? = nil) throws -> [String: CostSummary] {
        let statement = try database.prepare("""
            SELECT \(key) AS key, model, is_fast, (input + cache_read + cache_write > 100000) AS long_prompt,
                   count(*), sum(input), sum(output), sum(cache_read), sum(cache_write_5m),
                   sum(max(cache_write_1h, cache_write - cache_write_5m))
            FROM responses
            WHERE ts >= ? AND ts < ?
            GROUP BY key, model, is_fast, long_prompt
            """)
        var result: [String: CostSummary] = [:]
        try statement.run([
            .int(since.map { Int64($0.timeIntervalSince1970) } ?? 0),
            .int(until.map { Int64($0.timeIntervalSince1970) } ?? Int64.max),
        ]) { row in
            let label = row.text(0) ?? ""
            var summary = result[label] ?? CostSummary()
            if let price = Pricing.price(
                model: row.text(1) ?? "", isFast: row.int(2) != 0, isLongPrompt: row.int(3) != 0
            ) {
                summary.usd += Pricing.cost(
                    PricedTokens(
                        input: row.int(5), output: row.int(6), cacheRead: row.int(7),
                        write5m: row.int(8), write1h: row.int(9)
                    ),
                    at: price
                )
            } else {
                summary.unpricedReplies += row.int(4)
            }
            result[label] = summary
        }
        return result
    }

    /// When Claude Code last replied, according to its logs.
    public func latestReply(from source: Source) throws -> Date? {
        var latest: Date?
        try database.prepare("SELECT max(ts) FROM responses WHERE source = ?")
            .run([.text(source.rawValue)]) { row in
                if row.int(0) > 0 { latest = Date(timeIntervalSince1970: TimeInterval(row.int(0))) }
            }
        return latest
    }

    /// Rows are newest first when grouped by day, and largest first otherwise.
    public func report(by grouping: Grouping, since: Date? = nil) throws -> [ReportRow] {
        switch grouping {
        case .day:
            return try rows(selecting: "date(ts, 'unixepoch', 'localtime')", since: since)
                .sorted { $0.label > $1.label }
        case .model:
            return try rows(selecting: "model", since: since).sorted(by: Self.largestFirst)
        case .source:
            return try rows(selecting: "source", since: since)
                .map { ReportRow(label: Self.sourceName($0.label), totals: $0.totals, costUSD: $0.costUSD) }
                .sorted(by: Self.largestFirst)
        case .project:
            // Names come from every project ever seen, so a label doesn't change between reports.
            let names = Self.displayNames(forPaths: try rows(selecting: "project", since: nil).map(\.label))
            let rows = try rows(selecting: "project", since: since)
            return rows
                .map { ReportRow(label: names[$0.label] ?? $0.label, totals: $0.totals, costUSD: $0.costUSD) }
                .sorted(by: Self.largestFirst)
        }
    }

    /// When two projects share a folder name, adds the parent folder, such as "ios/Baby Tracker".
    static func displayNames(forPaths paths: [String]) -> [String: String] {
        let counts = Dictionary(grouping: paths) { ($0 as NSString).lastPathComponent }
        var names: [String: String] = [:]
        for path in paths {
            let name = (path as NSString).lastPathComponent
            if counts[name, default: []].count > 1 {
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                names[path] = "\(parent)/\(name)"
            } else {
                names[path] = name
            }
        }
        return names
    }

    private static func sourceName(_ raw: String) -> String {
        switch Source(rawValue: raw) {
        case .claudeCode: return "Claude Code"
        case .cowork: return "Cowork"
        case nil: return raw
        }
    }

    private static func largestFirst(_ a: ReportRow, _ b: ReportRow) -> Bool {
        a.totals.total != b.totals.total ? a.totals.total > b.totals.total : a.label < b.label
    }

    private func rows(selecting key: String, since: Date?) throws -> [ReportRow] {
        let statement = try database.prepare("""
            SELECT \(key) AS key, count(*), sum(input), sum(output), sum(cache_write), sum(cache_read)
            FROM responses
            WHERE ts >= ?
            GROUP BY key
            """)
        let costs = try costs(selecting: key, since: since)
        var rows: [ReportRow] = []
        try statement.run([.int(since.map { Int64($0.timeIntervalSince1970) } ?? 0)]) { row in
            var totals = TokenTotals()
            totals.replies = row.int(1)
            totals.input = row.int(2)
            totals.output = row.int(3)
            totals.cacheWrite = row.int(4)
            totals.cacheRead = row.int(5)
            let label = row.text(0) ?? ""
            let cost = costs[label]?.usd ?? 0
            rows.append(ReportRow(label: label, totals: totals, costUSD: cost > 0 ? cost : nil))
        }
        return rows
    }
}
