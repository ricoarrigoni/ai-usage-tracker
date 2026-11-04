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

    public init(label: String, totals: TokenTotals) {
        self.label = label
        self.totals = totals
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
                .map { ReportRow(label: Self.sourceName($0.label), totals: $0.totals) }
                .sorted(by: Self.largestFirst)
        case .project:
            let rows = try rows(selecting: "project", since: since)
            let names = Self.displayNames(forPaths: rows.map(\.label))
            return rows
                .map { ReportRow(label: names[$0.label] ?? $0.label, totals: $0.totals) }
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
        var rows: [ReportRow] = []
        try statement.run([.int(since.map { Int64($0.timeIntervalSince1970) } ?? 0)]) { row in
            var totals = TokenTotals()
            totals.replies = row.int(1)
            totals.input = row.int(2)
            totals.output = row.int(3)
            totals.cacheWrite = row.int(4)
            totals.cacheRead = row.int(5)
            rows.append(ReportRow(label: row.text(0) ?? "", totals: totals))
        }
        return rows
    }
}
