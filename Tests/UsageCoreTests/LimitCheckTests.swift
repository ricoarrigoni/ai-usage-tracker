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
}
