import Foundation

public enum TokenFormat {
    public static func short(_ number: Int64) -> String {
        let value = Double(number)
        switch number {
        case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return String(number)
        }
    }
}

public enum LimitLevel: Equatable, Sendable {
    case normal, nearLimit, reached

    init(percent: Int) {
        switch percent {
        case 100...: self = .reached
        case 80...: self = .nearLimit
        default: self = .normal
        }
    }
}

public struct LimitDisplay: Equatable, Sendable, Identifiable {
    public var kind: LimitKind
    public var percent: Int
    public var level: LimitLevel
    public var detail: String

    public var id: String { kind.rawValue }

    public init(kind: LimitKind, percent: Int, level: LimitLevel, detail: String) {
        self.kind = kind
        self.percent = percent
        self.level = level
        self.detail = detail
    }
}

public struct PaceMessage: Equatable, Sendable {
    public var text: String
    public var isWarning: Bool

    public init(text: String, isWarning: Bool) {
        self.text = text
        self.isWarning = isWarning
    }
}

public struct DayUsage: Equatable, Sendable, Identifiable {
    public var day: Date
    public var weekdayLetter: String
    public var total: Int64
    public var isToday: Bool

    public var id: Date { day }

    public init(day: Date, weekdayLetter: String, total: Int64, isToday: Bool) {
        self.day = day
        self.weekdayLetter = weekdayLetter
        self.total = total
        self.isToday = isToday
    }
}

/// Everything the menu bar and panel show, already worked out and ready to display.
public struct Dashboard: Equatable, Sendable {
    public var menuTitle = "AI –"
    public var limits: [LimitDisplay] = []
    public var pace: PaceMessage?
    public var freshness: String?
    public var isStale = false
    public var today = TokenTotals()
    public var days: [DayUsage] = []
    public var projects: [ReportRow] = []
    public var problem: String?

    public init() {}

    /// Tokens not served from cache: input, output and cache writes.
    public var todayNew: Int64 { today.input + today.output + today.cacheWrite }
}

extension Dashboard {
    /// How long a reading can go without news before pace stops being shown.
    static let staleAfter: TimeInterval = 30 * 60

    mutating func applyLimits(_ state: LimitState, lastReply: Date?, now: Date) {
        guard !state.windows.isEmpty, let newest = state.newestReading else {
            limits = []
            pace = nil
            freshness = nil
            isStale = false
            menuTitle = "AI –"
            return
        }

        // Open sessions repeat their last value every minute, so a new line doesn't mean new data.
        // A value is only as recent as its last change or the last Claude Code reply.
        var asOf = state.windows.values.map(\.lastChange).max() ?? newest
        if let lastReply { asOf = max(asOf, lastReply) }
        asOf = min(asOf, newest)
        let age = now.timeIntervalSince(asOf)
        isStale = age > Self.staleAfter
        freshness = "Updated \(Self.ageText(age))"

        limits = LimitKind.allCases.compactMap { kind in
            state.windows[kind].map { Self.display($0, now: now) }
        }
        let top = limits.max { $0.percent < $1.percent }
        menuTitle = top.map { "\($0.kind.shortTitle) \($0.percent)%" } ?? "AI –"
        pace = isStale ? nil : Self.pace(state, asOf: asOf, now: now)
    }

    static func display(_ window: LimitWindow, now: Date) -> LimitDisplay {
        guard let end = window.resetsAt else {
            let percent = Int(window.percent.rounded(.down))
            return LimitDisplay(
                kind: window.kind, percent: percent, level: LimitLevel(percent: percent),
                detail: "Reset time not known yet"
            )
        }
        if end <= now {
            return LimitDisplay(
                kind: window.kind, percent: 0, level: .normal,
                detail: "Reset at \(timeText(end, now: now)). Waiting for a new reading"
            )
        }
        let percent = Int(window.percent.rounded(.down))
        return LimitDisplay(
            kind: window.kind, percent: percent, level: LimitLevel(percent: percent),
            detail: "Resets \(timeText(end, now: now))"
        )
    }

    /// Projects the average rate so far across the rest of the window. Too early, it says nothing.
    static func pace(_ state: LimitState, asOf: Date, now: Date) -> PaceMessage? {
        var soonest: (kind: LimitKind, at: Date)?
        var enoughData = false

        for window in state.windows.values {
            guard let end = window.resetsAt, end > now, window.percent < 100 else { continue }
            let start = end.addingTimeInterval(-window.kind.length)
            let elapsed = asOf.timeIntervalSince(start)
            guard elapsed >= window.kind.length * 0.1, window.percent >= 5 else { continue }
            enoughData = true
            let remaining = (100 - window.percent) / (window.percent / elapsed)
            let hit = asOf.addingTimeInterval(remaining)
            if hit < end, soonest == nil || hit < soonest!.at {
                soonest = (window.kind, hit)
            }
        }

        if let soonest {
            return PaceMessage(
                text: "At this pace: \(soonest.kind.title) limit \(timeText(soonest.at, now: now))",
                isWarning: true
            )
        }
        return enoughData ? PaceMessage(text: "On pace to stay under your limits", isWarning: false) : nil
    }

    static func timeText(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func ageText(_ age: TimeInterval) -> String {
        switch age {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(age / 60)) min ago"
        case ..<86400: return "\(Int(age / 3600)) h ago"
        default: return "\(Int(age / 86400)) d ago"
        }
    }
}

/// Loads a fresh dashboard. Lives on its own actor so log reading never blocks the interface.
public actor DashboardEngine {
    private let store: UsageStore
    private let readingsFile: URL
    private var unreadableLines = 0

    public init(locations: Locations = .standard()) throws {
        store = try UsageStore(locations: locations)
        readingsFile = locations.dataDirectory.appendingPathComponent("readings.jsonl")
    }

    public func load(now: Date = Date()) throws -> Dashboard {
        unreadableLines += try store.sync().unrecognizedLines

        var dashboard = Dashboard()
        let readings = (try? LimitHistory.read(readingsFile)) ?? []
        dashboard.applyLimits(
            LimitMerger.merge(readings),
            lastReply: try store.latestReply(from: .claudeCode),
            now: now
        )

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        dashboard.today = try store.totals(since: today)
        dashboard.projects = Array(try store.report(by: .project, since: today).prefix(3))

        let firstDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let byDay = Dictionary(
            try store.report(by: .day, since: firstDay).map { ($0.label, $0.totals.total) },
            uniquingKeysWith: +
        )
        let keyFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        dashboard.days = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DayUsage(
                day: day,
                weekdayLetter: day.formatted(.dateTime.weekday(.narrow)),
                total: byDay[day.formatted(keyFormat)] ?? 0,
                isToday: day == today
            )
        }

        if unreadableLines > 0 {
            dashboard.problem = "\(unreadableLines) log lines couldn't be read, so totals may be low."
        }
        return dashboard
    }
}
