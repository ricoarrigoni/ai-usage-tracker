import Foundation

public enum LimitKind: String, CaseIterable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    public var title: String { self == .fiveHour ? "5-hour" : "7-day" }
    public var shortTitle: String { self == .fiveHour ? "5h" : "7d" }
    public var length: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 86400 }
}

/// One line of `readings.jsonl`, saved by the status line script.
public struct LimitReading: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Sendable {
        public var used_percentage: Double?
        public var resets_at: Int64?

        public init(used_percentage: Double?, resets_at: Int64?) {
            self.used_percentage = used_percentage
            self.resets_at = resets_at
        }
    }

    public struct Limits: Decodable, Equatable, Sendable {
        public var five_hour: Window?
        public var seven_day: Window?

        public init(five_hour: Window? = nil, seven_day: Window? = nil) {
            self.five_hour = five_hour
            self.seven_day = seven_day
        }
    }

    public var t: Int64
    public var rate_limits: Limits?

    public init(t: Int64, rate_limits: Limits?) {
        self.t = t
        self.rate_limits = rate_limits
    }

    func window(_ kind: LimitKind) -> Window? {
        kind == .fiveHour ? rate_limits?.five_hour : rate_limits?.seven_day
    }
}

public enum LimitHistory {
    /// Only the end of the file is read. The newest readings are the ones that decide current limits.
    public static func read(_ url: URL, tailBytes: UInt64 = 1 << 20) throws -> [LimitReading] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > tailBytes ? size - tailBytes : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(LimitReading.self, from: Data($0)) }
    }
}

/// The current state of one limit window.
public struct LimitWindow: Equatable, Sendable {
    public var kind: LimitKind
    public var percent: Double
    /// Nil just after a reset, when Claude Code can still report the time that has passed.
    public var resetsAt: Date?
    public var lastChange: Date
}

public struct LimitState: Equatable, Sendable {
    public var windows: [LimitKind: LimitWindow] = [:]
    public var newestReading: Date?

    public init() {}
}

/// Combines readings from all open sessions into one current state.
///
/// Sessions can hold older values or be missing a window. Usage only rises within a window, so
/// this keeps the highest value for the newest window. A reset time already in the past when it
/// was read means the window has reset, even though the time itself hasn't caught up yet.
public enum LimitMerger {
    private static let slack: Int64 = 60

    public static func merge(_ readings: [LimitReading]) -> LimitState {
        var state = LimitState()
        for reading in readings.sorted(by: { $0.t < $1.t }) {
            state.newestReading = Date(timeIntervalSince1970: TimeInterval(reading.t))
            for kind in LimitKind.allCases {
                guard let window = reading.window(kind),
                      let value = window.used_percentage,
                      let resets = window.resets_at
                else { continue }
                state.windows[kind] = apply(
                    value: value, resets: resets, at: reading.t, kind: kind, to: state.windows[kind]
                )
            }
        }
        return state
    }

    private static func apply(
        value: Double, resets: Int64, at time: Int64, kind: LimitKind, to current: LimitWindow?
    ) -> LimitWindow? {
        let readAt = Date(timeIntervalSince1970: TimeInterval(time))
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resets))
        let resetHasPassed = resets + slack < time

        func fresh(_ end: Date?) -> LimitWindow {
            LimitWindow(kind: kind, percent: value, resetsAt: end, lastChange: readAt)
        }
        func raised(_ window: LimitWindow, end: Date?) -> LimitWindow {
            var updated = window
            updated.resetsAt = end
            if value > window.percent {
                updated.percent = value
                updated.lastChange = readAt
            }
            return updated
        }

        guard let current else { return fresh(resetHasPassed ? nil : resetDate) }
        guard let currentEnd = current.resetsAt else {
            return raised(current, end: resetHasPassed ? nil : resetDate)
        }
        let currentResets = Int64(currentEnd.timeIntervalSince1970)

        if resetHasPassed {
            // A newer window's end time is already known, so this is an old session's reading.
            return currentResets > resets + slack ? current : fresh(nil)
        }
        if resets > currentResets + slack { return fresh(resetDate) }
        if resets < currentResets - slack { return current }
        return raised(current, end: currentEnd)
    }
}
