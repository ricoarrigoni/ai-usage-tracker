import Foundation
import Testing
@testable import UsageCore

@Suite struct LimitCheckTests {
    private func output(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func readsBothWindowsFromClaudeCodeOutput() throws {
        let data = output([
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.29,"resetsAt":1794716400},"seven_day":{"utilization":0.04,"resetsAt":1795024800}}}}"#,
            #"{"type":"result","is_error":false,"result":"OK"}"#,
        ])
        let reading = try LimitCheck.parse(data, at: 1000)
        #expect(reading.session == LimitCheck.session)
        #expect(reading.t == 1000)
        // 0.29 * 100 is 28.999… in floating point; it must still read as 29.
        #expect(reading.rate_limits?.five_hour == .init(used_percentage: 29, resets_at: 1794716400))
        #expect(reading.rate_limits?.seven_day == .init(used_percentage: 4, resets_at: 1795024800))
        #expect(reading.cost_usd == nil)
    }

    @Test func roundsDownLikeTheStatusLine() throws {
        let data = output([
            #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.137,"resetsAt":5}}}}"#,
        ])
        #expect(try LimitCheck.parse(data, at: 1).rate_limits?.five_hour?.used_percentage == 13)
    }

    @Test func reportsClaudeCodesErrorWhenThereAreNoLimits() {
        let data = output([#"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#])
        #expect(throws: LimitCheck.Failure.noLimits("Not logged in · Please run /login")) {
            try LimitCheck.parse(data, at: 1)
        }
    }

    @Test func savedReadingIsReadBackAndConfirmsFreshness() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("readings.jsonl")
        let reading = LimitReading(t: 50, session: LimitCheck.session, rate_limits: .init(
            five_hour: .init(used_percentage: 3, resets_at: 9000)
        ))
        try LimitCheck.append(reading, to: file)
        try LimitCheck.append(reading, to: file)
        let back = try LimitHistory.read(file)
        #expect(back == [reading, reading])
    }

    // Sunday 2026-11-15 03:00 in Madrid.
    private let now = Date(timeIntervalSince1970: 1_794_708_000)
    private func madrid(_ text: String) -> Date {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "Europe/Madrid")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.date(from: text)!
    }

    @Test func readsEveryLimitFromTheUsageCommand() throws {
        let text = """
            You are currently using your subscription to power your Claude Code usage

            Current session: 10% used · resets Nov 15 at 5:20am (Europe/Madrid)
            Current week (all models): 6% used · resets Nov 18 at 7pm (Europe/Madrid)
            Current week (Fable): 9% used · resets Nov 18 at 7pm (Europe/Madrid)

            What's contributing to your usage?
              43%  See what fills your context · run /context
            """
        let reading = try #require(LimitCheck.parseUsageText(text, now: now))
        let session = Int64(madrid("2026-11-15 05:20").timeIntervalSince1970)
        let week = Int64(madrid("2026-11-18 19:00").timeIntervalSince1970)
        #expect(reading.rate_limits?.five_hour == .init(used_percentage: 10, resets_at: session))
        #expect(reading.rate_limits?.seven_day == .init(used_percentage: 6, resets_at: week))
        #expect(reading.model_weeks == ["Fable": .init(used_percentage: 9, resets_at: week)])
        #expect(reading.session == LimitCheck.session)
    }

    @Test func readsTheJSONWrapperAndRejectsOtherOutput() {
        let wrapped = #"{"is_error":false,"result":"Current session: 4% used · resets 5:20am (Europe/Madrid)"}"#
        #expect(LimitCheck.parseUsage(Data(wrapped.utf8), now: now)?.rate_limits?.five_hour?.used_percentage == 4)
        let unknown = #"{"is_error":false,"result":"Unknown command: /usage"}"#
        #expect(LimitCheck.parseUsage(Data(unknown.utf8), now: now) == nil)
        #expect(LimitCheck.parseUsage(Data("not json".utf8), now: now) == nil)
    }

    @Test func readsResetTimesInTheirOwnTimeZone() {
        #expect(LimitCheck.resetDate("5:20am (Europe/Madrid)", now: now) == madrid("2026-11-15 05:20"))
        // A time already past today is tomorrow's.
        #expect(LimitCheck.resetDate("1am (Europe/Madrid)", now: now) == madrid("2026-11-16 01:00"))
        #expect(LimitCheck.resetDate("Nov 18 at 12pm (Europe/Madrid)", now: now) == madrid("2026-11-18 12:00"))
        #expect(LimitCheck.resetDate("Nov 18 at 12am (Europe/Madrid)", now: now) == madrid("2026-11-18 00:00"))
        // Near the end of the year, an early-January reset is next year's.
        let lateDecember = madrid("2026-12-30 10:00")
        #expect(LimitCheck.resetDate("Jan 2 at 7pm (Europe/Madrid)", now: lateDecember) == madrid("2027-01-02 19:00"))
        #expect(LimitCheck.resetDate("soon", now: now) == nil)
    }

    @Test func modelLimitsShowTheNewestCheckAndItsAge() {
        let end = Int64(now.timeIntervalSince1970) + 3 * 86400
        let old = LimitReading(t: Int64(now.timeIntervalSince1970) - 7200, session: LimitCheck.session,
                               rate_limits: nil, model_weeks: ["Fable": .init(used_percentage: 5, resets_at: end)])
        let newer = LimitReading(t: Int64(now.timeIntervalSince1970) - 3600, session: LimitCheck.session,
                                 rate_limits: nil, model_weeks: ["Fable": .init(used_percentage: 9, resets_at: end)])
        let statusLine = LimitReading(t: Int64(now.timeIntervalSince1970), rate_limits: nil)
        var dashboard = Dashboard()
        dashboard.applyModelLimits([old, newer, statusLine], now: now)
        #expect(dashboard.modelLimits.map(\.model) == ["Fable"])
        #expect(dashboard.modelLimits.first?.percent == 9)
        #expect(dashboard.modelLimits.first?.detail.hasSuffix("checked 1 h ago") == true)

        dashboard.applyModelLimits([statusLine], now: now)
        #expect(dashboard.modelLimits.isEmpty)
    }
}
