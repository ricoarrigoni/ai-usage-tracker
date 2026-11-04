import Foundation

public struct LimitAlert: Equatable, Sendable, Identifiable {
    public var kind: LimitKind
    public var windowEnd: Date
    public var threshold: Int
    public var percent: Int

    public var id: String { "\(kind.rawValue)-\(Int(windowEnd.timeIntervalSince1970))-\(threshold)" }
    public var title: String { "\(kind.title) limit at \(percent)%" }
    public func body(now: Date) -> String { "Resets \(Dashboard.timeText(windowEnd, now: now))." }
}

public enum LimitAlerts {
    public static let thresholds = [80, 95]

    /// The alert a window needs now, if any. Only the highest crossed threshold is sent, so
    /// jumping from 70% to 96% gives one alert rather than two.
    static func due(_ window: LimitWindow, alreadySent: Int, now: Date) -> LimitAlert? {
        guard let end = window.resetsAt, end > now else { return nil }
        let percent = Int(window.percent.rounded(.down))
        guard let threshold = thresholds.last(where: { percent >= $0 }), threshold > alreadySent else {
            return nil
        }
        return LimitAlert(kind: window.kind, windowEnd: end, threshold: threshold, percent: percent)
    }
}

extension UsageStore {
    func createAlertTable() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS sent_alerts (
                kind TEXT NOT NULL,
                window_end INTEGER NOT NULL,
                threshold INTEGER NOT NULL,
                PRIMARY KEY (kind, window_end)
            ) WITHOUT ROWID
            """)
    }

    /// Returns the alerts due now and records them, so each is only returned once, even across restarts.
    func takeDueAlerts(_ state: LimitState, now: Date) throws -> [LimitAlert] {
        var alerts: [LimitAlert] = []
        let lookup = try database.prepare("SELECT threshold FROM sent_alerts WHERE kind = ? AND window_end = ?")
        let record = try database.prepare("INSERT OR REPLACE INTO sent_alerts (kind, window_end, threshold) VALUES (?, ?, ?)")
        for kind in LimitKind.allCases {
            guard let window = state.windows[kind], let end = window.resetsAt else { continue }
            let endTime = Int64(end.timeIntervalSince1970)
            var sent = 0
            try lookup.run([.text(kind.rawValue), .int(endTime)]) { sent = Int($0.int(0)) }
            guard let alert = LimitAlerts.due(window, alreadySent: sent, now: now) else { continue }
            try record.run([.text(kind.rawValue), .int(endTime), .int(Int64(alert.threshold))])
            alerts.append(alert)
        }
        return alerts
    }
}
