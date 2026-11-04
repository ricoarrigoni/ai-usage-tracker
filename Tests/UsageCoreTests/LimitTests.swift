import Foundation
import Testing
@testable import UsageCore

private func reading(
    _ t: Int64, five: (Double, Int64)? = nil, seven: (Double, Int64)? = nil
) -> LimitReading {
    LimitReading(t: t, rate_limits: .init(
        five_hour: five.map { .init(used_percentage: $0.0, resets_at: $0.1) },
        seven_day: seven.map { .init(used_percentage: $0.0, resets_at: $0.1) }
    ))
}

private func date(_ t: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }

@Suite struct LimitMergerTests {
    @Test func sessionsDisagreeingDoesNotLowerAValue() {
        let state = LimitMerger.merge([
            reading(100, five: (1, 9000), seven: (29, 90000)),
            reading(160, seven: (29, 90000)),
            reading(220, five: (3, 9000), seven: (30, 90000)),
            reading(280, five: (1, 9000), seven: (29, 90000)),
        ])
        #expect(state.windows[.fiveHour]?.percent == 3)
        #expect(state.windows[.sevenDay]?.percent == 30)
        #expect(state.windows[.fiveHour]?.lastChange == date(220))
        #expect(state.newestReading == date(280))
    }

    @Test func aNewWindowReplacesTheOldOne() {
        let state = LimitMerger.merge([
            reading(100, five: (90, 1000)),
            reading(1100, five: (1, 19000)),
        ])
        #expect(state.windows[.fiveHour]?.percent == 1)
        #expect(state.windows[.fiveHour]?.resetsAt == date(19000))
    }

    /// The real sequence seen on Nov 4: after the reset, readings still gave the old reset time.
    @Test func staleResetTimeStillCountsAsANewWindow() {
        var readings = [reading(100, seven: (29, 1000))]
        readings.append(LimitReading(t: 1001, rate_limits: .init()))
        readings.append(reading(1500, seven: (0, 1000)))
        var state = LimitMerger.merge(readings)
        #expect(state.windows[.sevenDay]?.percent == 0)
        #expect(state.windows[.sevenDay]?.resetsAt == nil)

        readings.append(reading(1600, seven: (1, 1000)))
        state = LimitMerger.merge(readings)
        #expect(state.windows[.sevenDay]?.percent == 1)

        readings.append(reading(1700, seven: (2, 605800)))
        state = LimitMerger.merge(readings)
        #expect(state.windows[.sevenDay]?.percent == 2)
        #expect(state.windows[.sevenDay]?.resetsAt == date(605800))
    }

    @Test func anOldSessionCantBringBackAFinishedWindow() {
        let state = LimitMerger.merge([
            reading(1100, seven: (3, 605800)),
            reading(1200, seven: (29, 1000)),
        ])
        #expect(state.windows[.sevenDay]?.percent == 3)
    }

    @Test func readsTheEndOfALongFileAndSkipsBrokenLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = ""
        for t in 0..<100 {
            text += #"{"t":\#(t),"cost_usd":1.5,"rate_limits":null}"# + "\nnot json\n"
        }
        try Data(text.utf8).write(to: url)

        let all = try LimitHistory.read(url)
        #expect(all.count == 100)
        let tail = try LimitHistory.read(url, tailBytes: 200)
        #expect(tail.last?.t == 99)
        #expect(tail.count < 10)
    }
}

@Suite struct DashboardTests {
    private let now = date(1_000_000)

    private func window(_ kind: LimitKind, _ percent: Double, resets: Int64?, changed: Int64) -> LimitWindow {
        LimitWindow(kind: kind, percent: percent, resetsAt: resets.map(date), lastChange: date(changed))
    }

    private func state(_ windows: LimitWindow..., newest: Int64 = 1_000_000) -> LimitState {
        var s = LimitState()
        for w in windows { s.windows[w.kind] = w }
        s.newestReading = date(newest)
        return s
    }

    @Test func menuTitleShowsTheFullerLimit() {
        var d = Dashboard()
        d.applyLimits(
            state(window(.fiveHour, 12, resets: 1_010_000, changed: 999_990),
                  window(.sevenDay, 40, resets: 1_400_000, changed: 999_990)),
            lastReply: nil, now: now
        )
        #expect(d.menuTitle == "7d 40%")
        #expect(d.limits.map(\.kind) == [.fiveHour, .sevenDay])
    }

    @Test func repeatedReadingsDontMakeOldDataLookNew() {
        var d = Dashboard()
        d.applyLimits(
            state(window(.fiveHour, 50, resets: 1_010_000, changed: now.int - 7200)),
            lastReply: date(now.int - 7200), now: now
        )
        #expect(d.freshness == "Updated 2 h ago")
        #expect(d.isStale)
        #expect(d.pace == nil)
    }

    @Test func aReplyWithNoChangeStillCountsAsFresh() {
        var d = Dashboard()
        d.applyLimits(
            state(window(.fiveHour, 50, resets: 1_010_000, changed: now.int - 7200)),
            lastReply: date(now.int - 120), now: now
        )
        #expect(d.freshness == "Updated 2 min ago")
        #expect(!d.isStale)
    }

    @Test func aPassedResetShowsZeroAndSaysSo() {
        let shown = Dashboard.display(window(.fiveHour, 90, resets: now.int - 60, changed: now.int - 600), now: now)
        #expect(shown.percent == 0)
        #expect(shown.level == .normal)
        #expect(shown.detail.hasPrefix("Reset at"))
    }

    @Test func unknownResetTimeIsSaid() {
        let shown = Dashboard.display(window(.sevenDay, 2, resets: nil, changed: now.int), now: now)
        #expect(shown.percent == 2)
        #expect(shown.detail == "Reset time not known yet")
    }

    @Test(arguments: [(79.0, LimitLevel.normal), (80.0, .nearLimit), (99.9, .nearLimit), (100.0, .reached)])
    func levels(percent: Double, level: LimitLevel) {
        #expect(Dashboard.display(window(.fiveHour, percent, resets: now.int + 60, changed: now.int), now: now).level == level)
    }

    @Test func paceWarnsWhenTheLimitWillBeHitBeforeReset() throws {
        // One hour into the 5-hour window at 50%: 100% arrives after another hour.
        let end = now.int + 4 * 3600
        let s = state(window(.fiveHour, 50, resets: end, changed: now.int))
        let pace = try #require(Dashboard.pace(s, asOf: now, now: now))
        #expect(pace.isWarning)
        #expect(pace.text.contains("5-hour"))
    }

    @Test func paceIsCalmWhenUnderTheLimit() throws {
        // Four hours in at 50%: reset arrives before the limit.
        let s = state(window(.fiveHour, 50, resets: now.int + 3600, changed: now.int))
        let pace = try #require(Dashboard.pace(s, asOf: now, now: now))
        #expect(!pace.isWarning)
    }

    @Test func paceSaysNothingTooEarlyOrWithTooLittleUse() {
        let early = state(window(.fiveHour, 50, resets: now.int + 5 * 3600 - 600, changed: now.int))
        #expect(Dashboard.pace(early, asOf: now, now: now) == nil)
        let little = state(window(.fiveHour, 2, resets: now.int + 3600, changed: now.int))
        #expect(Dashboard.pace(little, asOf: now, now: now) == nil)
    }
}

private extension Date {
    var int: Int64 { Int64(timeIntervalSince1970) }
}

@Suite struct EngineTests {
    @Test func fillsEveryDayAndReadsLimits() async throws {
        let sandbox = try Sandbox()
        let now = Date()
        let stamp = now.addingTimeInterval(-60).formatted(.iso8601)
        _ = try sandbox.write(reply(timestamp: stamp), to: "\(appFolder)/s.jsonl")
        let t = Int64(now.timeIntervalSince1970)
        let line = #"{"t":\#(t),"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":\#(t + 3600)}}}"# + "\n"
        try FileManager.default.createDirectory(at: sandbox.locations.dataDirectory, withIntermediateDirectories: true)
        try Data(line.utf8).write(to: sandbox.locations.dataDirectory.appendingPathComponent("readings.jsonl"))

        let dashboard = try await DashboardEngine(locations: sandbox.locations).load(now: now)
        #expect(dashboard.menuTitle == "5h 12%")
        #expect(dashboard.days.count == 7)
        #expect(dashboard.days.last?.isToday == true)
        #expect(dashboard.days.last?.total == 100)
        #expect(dashboard.projects.first?.label == "App")
    }

    @Test func noReadingsIsAnEmptyStateNotAnError() async throws {
        let sandbox = try Sandbox()
        let dashboard = try await DashboardEngine(locations: sandbox.locations).load()
        #expect(dashboard.limits.isEmpty)
        #expect(dashboard.menuTitle == "AI –")
        #expect(dashboard.problem == nil)
    }
}

private func costReading(_ t: Int64, session: String = "a", cost: Double?, five: Double? = nil, resets: Int64 = 18000) -> LimitReading {
    LimitReading(
        t: t, session: session, cost_usd: cost,
        rate_limits: .init(five_hour: five.map { .init(used_percentage: $0, resets_at: resets) })
    )
}

@Suite struct CostLedgerTests {
    @Test func firstSampleOnlySetsTheStartingPoint() {
        let ledger = CostLedger(readings: [
            costReading(100, cost: 5.0), costReading(200, cost: 6.5),
        ])
        #expect(ledger.spend(from: date(0), to: date(300)) == 1.5)
    }

    @Test func spendIsLimitedToThePeriodAndAddsSessions() {
        let ledger = CostLedger(readings: [
            costReading(100, cost: 1), costReading(200, cost: 2), costReading(300, cost: 4),
            costReading(100, session: "b", cost: 0), costReading(300, session: "b", cost: 3),
        ])
        #expect(ledger.spend(from: date(200), to: date(300)) == 5)
        #expect(ledger.spend(from: date(100), to: date(200)) == 1)
    }

    @Test func clearDoesNotCountAsNegativeSpend() {
        let ledger = CostLedger(readings: [
            costReading(100, cost: 9), costReading(200, cost: 0), costReading(300, cost: 2),
        ])
        #expect(ledger.spend(from: date(0), to: date(400)) == 2)
    }
}

@Suite struct AttributionTests {
    private let now = date(10000)

    /// A rise of `points` for each `dollars`, three times over.
    private func calibratedReadings(dollarsPerStep: Double, pointsPerStep: Double, steps: Int = 4) -> [LimitReading] {
        (0...steps).map { i in
            costReading(Int64(100 + i * 100), cost: Double(i) * dollarsPerStep, five: Double(i) * pointsPerStep)
        }
    }

    private func attribution(_ readings: [LimitReading]) -> LimitAttribution {
        LimitAttribution(
            history: LimitMerger.history(readings, kind: .fiveHour),
            ledger: CostLedger(readings: readings),
            now: now
        )
    }

    @Test func staysInLearningModeUntilThereAreEnoughMeasurements() {
        let few = attribution(calibratedReadings(dollarsPerStep: 1, pointsPerStep: 4, steps: 2))
        #expect(few.pointsPerDollar == nil)
        #expect(few.status(since: date(0)) == .learning(measurements: 2, needed: 3))
    }

    @Test func allClaudeCodeUseIsExplainedByClaudeCode() {
        let result = attribution(calibratedReadings(dollarsPerStep: 1, pointsPerStep: 4))
        #expect(result.pointsPerDollar == 4)
        #expect(result.status(since: date(0)) == .ready(claudeCodePercent: 100, otherPercent: 0, points: 16))
    }

    @Test func aRiseWithoutSpendingGoesToOther() throws {
        var readings = calibratedReadings(dollarsPerStep: 1, pointsPerStep: 4)
        // 16 points from Claude Code, then 16 more with no Claude Code spending.
        readings.append(costReading(600, cost: 4, five: 32))
        let result = attribution(readings)
        #expect(result.pointsPerDollar == 4)
        #expect(result.status(since: date(0)) == .ready(claudeCodePercent: 50, otherPercent: 50, points: 32))
        let window = try #require(result.windows.first)
        #expect(window.peak == 32)
        #expect(window.claudeCode == 16)
        #expect(window.other == 16)
    }

    @Test func rateComesFromTheLowEndSoOtherUseDoesntInflateIt() {
        // Four rises at 4 points per dollar, and one inflated by Cowork running at the same time.
        var readings = calibratedReadings(dollarsPerStep: 1, pointsPerStep: 4)
        readings.append(costReading(600, cost: 5, five: 36))
        #expect(attribution(readings).pointsPerDollar == 4)
    }

    @Test func smallRisesAreCombinedBeforeMeasuring() {
        // +1 per reading is too rough on its own, so rises are grouped until they reach 3.
        let readings = (0...9).map { i in
            costReading(Int64(100 + i * 100), cost: Double(i) * 0.5, five: Double(i))
        }
        let result = attribution(readings)
        #expect(result.measurements == 3)
        #expect(result.pointsPerDollar == 2)
    }

    @Test func pointsBeforeCostTrackingAreLeftOut() throws {
        var readings = [costReading(100, cost: nil, five: 40)]
        readings += (0...4).map { i in
            costReading(Int64(200 + i * 100), cost: Double(i), five: 40 + Double(i) * 4)
        }
        let result = attribution(readings)
        let window = try #require(result.windows.first)
        #expect(window.peak == 56)
        #expect(window.measuredPoints == 16)
        #expect(window.other == 0)
    }

    @Test func windowsEntirelyBeforeTrackingHaveNoSplit() throws {
        let old = costReading(100, cost: nil, five: 30, resets: 1000)
        var readings = [old]
        readings += (0...4).map { i in
            costReading(Int64(2000 + i * 100), cost: Double(i), five: Double(i) * 4, resets: 20000)
        }
        let result = attribution(readings)
        #expect(result.windows.count == 2)
        #expect(result.windows[0].claudeCode == nil)
        #expect(result.windows[0].measuredPoints == 0)
        #expect(result.windows[1].claudeCode == 16)
    }
}

@Suite struct ReadingStoreTests {
    private func line(_ t: Int, session: String = "a", percent: Int, cost: Double?) -> String {
        let costText = cost.map { String($0) } ?? "null"
        return #"{"t":\#(t),"session":"\#(session)","cost_usd":\#(costText),"rate_limits":{"five_hour":{"used_percentage":\#(percent),"resets_at":18000}}}"# + "\n"
    }

    @Test func repeatsAreSkippedAndNewLinesPickedUp() throws {
        let sandbox = try Sandbox()
        let store = try UsageStore(locations: sandbox.locations)
        let file = sandbox.root.appendingPathComponent("readings.jsonl")
        try Data((line(100, percent: 1, cost: 1) + line(160, percent: 1, cost: 1) + line(220, percent: 2, cost: 1.5)).utf8).write(to: file)

        try store.syncReadings(from: file)
        #expect(try store.allReadings().map(\.t) == [100, 220])

        try sandbox.append(line(280, percent: 2, cost: 1.5) + line(340, session: "b", percent: 2, cost: 0), to: file)
        try store.syncReadings(from: file)
        let all = try store.allReadings()
        #expect(all.map(\.t) == [100, 220, 340])
        #expect(all.last?.session == "b")
        #expect(all[1].cost_usd == 1.5)
        #expect(all[1].rate_limits?.five_hour?.resets_at == 18000)

        // Reading the file again adds nothing.
        try store.syncReadings(from: file)
        #expect(try store.allReadings().count == 3)
    }

    @Test func unfinishedLineWaitsUntilComplete() throws {
        let sandbox = try Sandbox()
        let store = try UsageStore(locations: sandbox.locations)
        let file = sandbox.root.appendingPathComponent("readings.jsonl")
        let second = line(200, percent: 2, cost: 2)
        let cut = second.index(second.startIndex, offsetBy: 20)
        try Data((line(100, percent: 1, cost: 1) + second[..<cut]).utf8).write(to: file)
        try store.syncReadings(from: file)
        #expect(try store.allReadings().count == 1)

        try sandbox.append(String(second[cut...]), to: file)
        try store.syncReadings(from: file)
        #expect(try store.allReadings().count == 2)
    }

    @Test func missingFileIsFine() throws {
        let sandbox = try Sandbox()
        let store = try UsageStore(locations: sandbox.locations)
        try store.syncReadings(from: sandbox.root.appendingPathComponent("nope.jsonl"))
        #expect(try store.allReadings().isEmpty)
    }
}

@Suite struct HistoryTests {
    @Test func coversEveryDayInRangeWithTotals() async throws {
        let sandbox = try Sandbox()
        let now = Date()
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        _ = try sandbox.write(
            reply(id: "a", timestamp: now.addingTimeInterval(-60).formatted(.iso8601))
                + reply(id: "b", model: "other", timestamp: threeDaysAgo.formatted(.iso8601)),
            to: "\(appFolder)/s.jsonl"
        )
        let engine = try DashboardEngine(locations: sandbox.locations)

        let week = try await engine.history(days: 7, now: now)
        #expect(week.days.count == 7)
        #expect(week.days.filter { $0.totals.replies > 0 }.count == 2)
        #expect(week.totals.replies == 2)
        #expect(week.models.count == 2)
        #expect(week.costUSD == nil)

        let two = try await engine.history(days: 2, now: now)
        #expect(two.totals.replies == 1)

        let all = try await engine.history(days: nil, now: now)
        #expect(all.days.count == 4)
        #expect(all.days.first?.totals.replies == 1)
    }
}
