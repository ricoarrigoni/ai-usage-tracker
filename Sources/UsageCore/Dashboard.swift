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
    /// Current session, today, the last 7 days and the last 30 days, at API list prices.
    public var costs: [CostPeriod] = []
    /// Replies in the last 30 days left out of `costs` because their model has no known price.
    public var unpricedReplies: Int64 = 0
    public var money = MoneyFormat.usd
    public var limitSplit: LimitSplitStatus?
    public var days: [DayUsage] = []
    public var projects: [ReportRow] = []
    public var problem: String?
    /// Alerts to deliver now. Only filled in when loading with `takeAlerts`.
    public var alerts: [LimitAlert] = []

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
                text: "At this pace, you'll reach your \(soonest.kind.limitName) around \(timeText(soonest.at, now: now))",
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
    private let locations: Locations
    private var lastRateAttempt: Date?

    public init(locations: Locations = .standard()) throws {
        self.locations = locations
        store = try UsageStore(locations: locations)
        readingsFile = locations.dataDirectory.appendingPathComponent("readings.jsonl")
    }

    /// Downloads exchange rates when the saved ones are over a day old and this Mac's currency isn't
    /// dollars. Only the app calls this, and the request carries no information about you or your
    /// usage. Returns true when there are new rates to show.
    public func updateExchangeRates(
        now: Date = Date(),
        locale: Locale = .current,
        fetch: @Sendable (URL) async throws -> Data = { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            return try await URLSession(configuration: .ephemeral).data(for: request).0
        }
    ) async -> Bool {
        guard let code = locale.currency?.identifier, code != "USD" else { return false }
        let file = ExchangeRates.file(in: locations)
        if let saved = ExchangeRates.load(from: file),
           now.timeIntervalSince1970 - Double(saved.fetchedAt) < 24 * 3600 { return false }
        if let lastRateAttempt, now.timeIntervalSince(lastRateAttempt) < 3600 { return false }
        lastRateAttempt = now

        guard let data = try? await fetch(ExchangeRates.source),
              let rates = ExchangeRates.parse(data, fetchedAt: now),
              let encoded = try? JSONEncoder().encode(rates)
        else { return false }
        try? FileManager.default.createDirectory(at: locations.dataDirectory, withIntermediateDirectories: true)
        try? encoded.write(to: file, options: .atomic)
        return true
    }

    private static let dayKeyFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    /// The numbers for the history window. A nil `days` means everything recorded.
    public func history(days: Int?, now: Date = Date()) throws -> UsageHistory {
        try store.sync()
        try store.syncReadings(from: readingsFile)

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = days.flatMap { calendar.date(byAdding: .day, value: -($0 - 1), to: today) }

        var result = UsageHistory()
        result.money = .current(locations: locations)
        result.totals = try store.totals(since: since)
        result.projects = try store.report(by: .project, since: since)
        result.models = try store.report(by: .model, since: since)

        let rows = try store.report(by: .day, since: since)
        let byDay = Dictionary(rows.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let firstKey = rows.last?.label
        let firstRecorded = firstKey.flatMap { try? Self.dayKeyFormat.parse($0) }
        var day = since ?? firstRecorded.map { calendar.startOfDay(for: $0) } ?? today
        while day <= today {
            let row = byDay[day.formatted(Self.dayKeyFormat)]
            result.days.append(UsageHistory.Day(
                date: day, totals: row?.totals ?? TokenTotals(), costUSD: row?.costUSD
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let stored = try store.allReadings()
        let ledger = CostLedger(readings: stored)
        let from = since ?? Date(timeIntervalSince1970: 0)
        let cost = try store.cost(since: since)
        result.costUSD = cost.usd > 0 ? cost.usd : nil
        result.unpricedReplies = cost.unpricedReplies

        let attribution = LimitAttribution(
            history: LimitMerger.history(stored, kind: .fiveHour), ledger: ledger, now: now
        )
        result.limitSplit = attribution.status(since: from)
        result.windows = attribution.windows.filter { ($0.end ?? now) >= from }.reversed()
        return result
    }

    /// `takeAlerts` marks due alerts as sent, so only the running app should use it.
    public func load(now: Date = Date(), takeAlerts: Bool = false) throws -> Dashboard {
        unreadableLines += try store.sync().unrecognizedLines
        try store.syncReadings(from: readingsFile)
        try store.trimReadings(file: readingsFile)

        var dashboard = Dashboard()
        dashboard.money = .current(locations: locations)
        let readings = (try? LimitHistory.read(readingsFile)) ?? []
        let limitState = LimitMerger.merge(readings)
        if takeAlerts {
            dashboard.alerts = try store.takeDueAlerts(limitState, now: now)
        }
        dashboard.applyLimits(
            limitState,
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
        let keyFormat = Self.dayKeyFormat
        dashboard.days = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DayUsage(
                day: day,
                weekdayLetter: day.formatted(.dateTime.weekday(.narrow)),
                total: byDay[day.formatted(keyFormat)] ?? 0,
                isToday: day == today
            )
        }

        let stored = try store.allReadings()
        let ledger = CostLedger(readings: stored)
        let attribution = LimitAttribution(
            history: LimitMerger.history(stored, kind: .fiveHour), ledger: ledger, now: now
        )
        let weekEnd = LimitMerger.merge(stored).windows[.sevenDay]?.resetsAt
        let weekStart = weekEnd.flatMap { $0 > now ? $0.addingTimeInterval(-LimitKind.sevenDay.length) : nil }
            ?? now.addingTimeInterval(-LimitKind.sevenDay.length)
        dashboard.limitSplit = attribution.status(since: weekStart)

        // Rolling periods, so a longer one never shows less than a shorter one, as a weekly limit
        // that reset today or a month that just began would. They match the history window.
        let sevenDays = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDays = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let thirtyDayCost = try store.cost(since: thirtyDays)
        let sessionStart = limitState.windows[.fiveHour]?.resetsAt.flatMap {
            $0 > now ? $0.addingTimeInterval(-LimitKind.fiveHour.length) : nil
        }
        dashboard.costs = [
            CostPeriod(title: "Session", usd: try sessionStart.map { try store.cost(since: $0).usd }),
            CostPeriod(title: "Today", usd: try store.cost(since: today).usd),
            CostPeriod(title: "7 days", usd: try store.cost(since: sevenDays).usd),
            CostPeriod(title: "30 days", usd: thirtyDayCost.usd),
        ]
        dashboard.unpricedReplies = thirtyDayCost.unpricedReplies

        if unreadableLines > 0 {
            dashboard.problem = "\(unreadableLines) log lines couldn't be read, so totals may be low."
        }
        return dashboard
    }
}
