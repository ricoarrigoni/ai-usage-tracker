import Foundation

/// Claude Code's own running cost for each session, from status line readings.
public struct CostLedger: Sendable {
    private struct Sample: Sendable {
        var time: Date
        var cost: Double
    }

    private var sessions: [String: [Sample]] = [:]
    public private(set) var firstSample: Date?

    public init(readings: [LimitReading]) {
        for reading in readings.sorted(by: { $0.t < $1.t }) {
            guard let cost = reading.cost_usd else { continue }
            let time = Date(timeIntervalSince1970: TimeInterval(reading.t))
            sessions[reading.session ?? "", default: []].append(Sample(time: time, cost: cost))
            firstSample = firstSample ?? time
        }
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// Dollars spent between two times, at list price, across all sessions.
    ///
    /// A session's first sample only sets its starting point, because a resumed session already
    /// has earlier cost in it. A drop means `/clear` started the count again.
    public func spend(from start: Date, to end: Date) -> Double {
        var total = 0.0
        for samples in sessions.values {
            var previous: Double?
            for sample in samples {
                if sample.time > end { break }
                if sample.time > start, let previous, sample.cost > previous {
                    total += sample.cost - previous
                }
                previous = sample.cost
            }
        }
        return total
    }
}

/// One 5-hour window, split into what Claude Code explains and the remainder.
public struct WindowSplit: Equatable, Sendable, Identifiable {
    public var start: Date?
    public var end: Date?
    public var peak: Int
    /// Limit points in the part of this window with cost data.
    public var measuredPoints: Double
    public var claudeCode: Double?
    public var other: Double?

    public var id: Double { (end ?? start ?? .distantPast).timeIntervalSince1970 }
}

public enum LimitSplitStatus: Equatable, Sendable {
    /// Not enough measurements yet to say what a dollar of Claude Code costs in limit points.
    case learning(measurements: Int, needed: Int)
    case ready(claudeCodePercent: Int, otherPercent: Int, points: Int)
}

/// Estimates how much of the 5-hour limit Claude Code used. The rest belongs to chat, Cowork and
/// anything else that counts against the limit.
public struct LimitAttribution: Sendable {
    /// A rise must be at least this big, since limits are whole percentages.
    static let minimumRise = 3.0
    static let minimumSpend = 0.05
    static let measurementsNeeded = 3

    public private(set) var measurements = 0
    public private(set) var pointsPerDollar: Double?
    public private(set) var windows: [WindowSplit] = []

    public init(history: [LimitWindowHistory], ledger: CostLedger, now: Date) {
        var rates: [Double] = []
        for window in history {
            guard var anchor = window.samples.first else { continue }
            for sample in window.samples.dropFirst() where sample.percent - anchor.percent >= Self.minimumRise {
                let spent = ledger.spend(from: anchor.time, to: sample.time)
                if spent >= Self.minimumSpend {
                    rates.append((sample.percent - anchor.percent) / spent)
                }
                anchor = sample
            }
        }
        measurements = rates.count

        // Other use can only make a limit rise faster than Claude Code explains, so the true rate
        // sits near the low end. The lowest value alone would be too exposed to rounding.
        if rates.count >= Self.measurementsNeeded {
            pointsPerDollar = rates.sorted()[rates.count / 4]
        }

        windows = history.map { split($0, ledger: ledger, now: now) }
    }

    private func split(_ window: LimitWindowHistory, ledger: CostLedger, now: Date) -> WindowSplit {
        var result = WindowSplit(
            start: window.start, end: window.end, peak: Int(window.peak), measuredPoints: 0
        )
        guard let tracked = ledger.firstSample, let start = window.start,
              (window.end ?? now) > tracked
        else { return result }

        // Only the part of a window after cost tracking began can be compared with spending.
        let from = max(start, tracked)
        let startingPercent = window.samples.last { $0.time <= from }?.percent ?? 0
        let points = max(0, window.peak - startingPercent)
        result.measuredPoints = points

        if let pointsPerDollar {
            let spent = ledger.spend(from: from, to: min(window.end ?? now, now))
            let claudeCode = min(points, spent * pointsPerDollar)
            result.claudeCode = claudeCode
            result.other = points - claudeCode
        }
        return result
    }

    public func status(since: Date) -> LimitSplitStatus? {
        guard pointsPerDollar != nil else {
            return .learning(measurements: measurements, needed: Self.measurementsNeeded)
        }
        let included = windows.filter { ($0.end ?? .distantFuture) > since && $0.claudeCode != nil }
        let points = included.reduce(0) { $0 + $1.measuredPoints }
        guard points >= 1 else { return nil }
        let claudeCode = included.reduce(0) { $0 + ($1.claudeCode ?? 0) }
        let share = Int((claudeCode / points * 100).rounded())
        return .ready(claudeCodePercent: share, otherPercent: 100 - share, points: Int(points.rounded()))
    }
}

/// The numbers behind the history window.
public struct UsageHistory: Equatable, Sendable {
    public struct Day: Equatable, Sendable, Identifiable {
        public var date: Date
        public var totals: TokenTotals

        public var id: Date { date }
        public var newTokens: Int64 { totals.input + totals.output + totals.cacheWrite }
    }

    public var totals = TokenTotals()
    public var days: [Day] = []
    public var projects: [ReportRow] = []
    public var models: [ReportRow] = []
    public var costUSD: Double?
    public var costTrackedSince: Date?
    public var limitSplit: LimitSplitStatus?
    public var windows: [WindowSplit] = []

    public init() {}
}
