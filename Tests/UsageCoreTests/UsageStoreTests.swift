import Foundation
import Testing
@testable import UsageCore

/// A throwaway set of folders laid out like a real Mac.
struct Sandbox {
    let root: URL
    let locations: Locations

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        locations = Locations(
            dataDirectory: root.appendingPathComponent("data"),
            claudeCodeProjects: root.appendingPathComponent("claude/projects"),
            coworkSessions: root.appendingPathComponent("cowork")
        )
        try FileManager.default.createDirectory(at: locations.claudeCodeProjects, withIntermediateDirectories: true)
    }

    func write(_ text: String, to relativePath: String, under base: URL? = nil) throws -> URL {
        let url = (base ?? locations.claudeCodeProjects).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

func reply(
    id: String = "msg_1",
    input: Int = 10,
    output: Int = 20,
    cacheWrite: Int = 30,
    cacheRead: Int = 40,
    model: String = "claude-opus-5-5",
    cwd: String = "/Users/me/Projects/App",
    timestamp: String = "2026-11-04T12:00:00.000Z",
    text: String = "hello"
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","cwd":"\(cwd)","sessionId":"s1","isSidechain":false,\
    "message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"\(text)"}],\
    "usage":{"input_tokens":\(input),"output_tokens":\(output),\
    "cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}

    """
}

let appFolder = "-Users-me-Projects-App"

@Suite struct SyncTests {
    @Test func repeatedLinesCountOnceAndKeepTheHighestValues() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(
            reply(output: 5) + reply(output: 20) + reply(output: 12),
            to: "\(appFolder)/session.jsonl"
        )
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        let totals = try store.totals()
        #expect(totals.replies == 1)
        #expect(totals.output == 20)
        #expect(totals.input == 10)
        #expect(totals.total == 100)
    }

    @Test func secondSyncReadsOnlyWhatIsNew() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write(reply(id: "a"), to: "\(appFolder)/session.jsonl")
        let store = try UsageStore(locations: sandbox.locations)

        #expect(try store.sync().filesRead == 1)
        #expect(try store.sync().filesRead == 0)

        try sandbox.append(reply(id: "b"), to: file)
        #expect(try store.sync().filesRead == 1)
        #expect(try store.totals().replies == 2)
    }

    @Test func unfinishedLastLineIsReadOnceComplete() throws {
        let sandbox = try Sandbox()
        let complete = reply(id: "b")
        let cut = complete.index(complete.startIndex, offsetBy: 40)
        let file = try sandbox.write(reply(id: "a") + complete[..<cut], to: "\(appFolder)/session.jsonl")
        let store = try UsageStore(locations: sandbox.locations)

        let first = try store.sync()
        #expect(first.unrecognizedLines == 0)
        #expect(try store.totals().replies == 1)

        try sandbox.append(String(complete[cut...]), to: file)
        try store.sync()
        #expect(try store.totals().replies == 2)
    }

    @Test func lastLineWithoutNewlineIsCountedOnce() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write(
            reply(id: "a").trimmingCharacters(in: .newlines),
            to: "\(appFolder)/session.jsonl"
        )
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()
        #expect(try store.totals().replies == 1)

        try sandbox.append("\n" + reply(id: "b"), to: file)
        try store.sync()
        let totals = try store.totals()
        #expect(totals.replies == 2)
        #expect(totals.total == 200)
    }

    @Test func historySurvivesDeletedLogs() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write(reply(), to: "\(appFolder)/session.jsonl")
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        try FileManager.default.removeItem(at: file)
        try store.sync()
        #expect(try store.totals().replies == 1)
    }

    @Test func replacedFileIsReadFromTheStart() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.write(reply(id: "a") + reply(id: "b"), to: "\(appFolder)/session.jsonl")
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        try FileManager.default.removeItem(at: file)
        _ = try sandbox.write(reply(id: "c"), to: "\(appFolder)/session.jsonl")
        try store.sync()
        #expect(try store.totals().replies == 3)
    }

    @Test func historySurvivesReopeningTheStore() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(reply(), to: "\(appFolder)/session.jsonl")
        try UsageStore(locations: sandbox.locations).sync()

        let reopened = try UsageStore(locations: sandbox.locations)
        #expect(try reopened.sync().filesRead == 0)
        #expect(try reopened.totals().replies == 1)
    }

    @Test func nonUsageLinesAreIgnoredAndBrokenOnesAreReported() throws {
        let sandbox = try Sandbox()
        let userLine = #"{"type":"user","message":{"content":"my \"usage\" is high"}}"# + "\n"
        let stringMessage = #"{"type":"attachment","message":"usage","usage":{}}"# + "\n"
        let synthetic = reply(id: "x", model: "<synthetic>")
        let noTokens = #"{"type":"assistant","timestamp":"2026-11-04T12:00:00Z","message":{"id":"y","model":"m","usage":{"speed":"new"}}}"# + "\n"
        let broken = #"{"type":"assistant","usage": not json"# + "\n"
        _ = try sandbox.write(
            userLine + stringMessage + synthetic + noTokens + broken + reply(id: "ok"),
            to: "\(appFolder)/session.jsonl"
        )
        let store = try UsageStore(locations: sandbox.locations)
        let summary = try store.sync()
        #expect(summary.unrecognizedLines == 2)
        #expect(try store.totals().replies == 1)
    }

    @Test func messageTextIsNeverStored() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(reply(text: "TOP-SECRET-PROMPT"), to: "\(appFolder)/session.jsonl")
        try UsageStore(locations: sandbox.locations).sync()

        let files = try FileManager.default.contentsOfDirectory(
            at: sandbox.locations.dataDirectory, includingPropertiesForKeys: nil
        )
        #expect(!files.isEmpty)
        for file in files {
            #expect(try Data(contentsOf: file).range(of: Data("TOP-SECRET-PROMPT".utf8)) == nil)
        }
    }

    @Test func coworkUsesTranscriptsAndSkipsAuditCopies() throws {
        let sandbox = try Sandbox()
        let base = sandbox.locations.coworkSessions
        _ = try sandbox.write(reply(id: "c1"), to: "a/b/local_1/audit.jsonl", under: base)
        _ = try sandbox.write(reply(id: "c1"), to: "a/b/local_1/.claude/projects/x/s.jsonl", under: base)
        _ = try sandbox.write(reply(id: "only-audit"), to: "a/b/local_2/audit.jsonl", under: base)
        _ = try sandbox.write(reply(id: "cc"), to: "\(appFolder)/session.jsonl")

        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        let sources = try store.report(by: .source)
        #expect(sources.map(\.label).sorted() == ["Claude Code", "Cowork"])
        #expect(sources.allSatisfy { $0.totals.replies == 1 })
        #expect(try store.report(by: .project).map(\.label).sorted() == ["App", "Cowork"])
    }
}

@Suite struct ProjectTests {
    @Test(arguments: [
        ("/Users/me/Projects/App", "/Users/me/Projects/App"),
        ("/Users/me/Projects/App/src/core", "/Users/me/Projects/App"),
        ("/Users/me/Projects/App/node_modules/astro/dist", "/Users/me/Projects/App"),
        ("/Users/me/Projects/App/.claude/worktrees/agent-abc", "/Users/me/Projects/App"),
        ("/Users/me/Elsewhere/Thing", "/Users/me/Elsewhere/Thing"),
    ])
    func findsTheProject(cwd: String, expected: String) {
        #expect(ProjectResolver.projectPath(cwd: cwd, logFolderName: appFolder) == expected)
    }

    @Test func encodesPathsLikeClaudeCode() {
        #expect(ProjectResolver.encode("/Users/me/AI Usage Tracker") == "-Users-me-AI-Usage-Tracker")
        #expect(ProjectResolver.encode("/a/b.c_d-é") == "-a-b-c-d--")
    }

    @Test func projectsWithTheSameNameStayApart() {
        let names = UsageStore.displayNames(forPaths: ["/p/Baby Tracker", "/p/ios/Baby Tracker", "/p/Site"])
        #expect(names["/p/Baby Tracker"] == "p/Baby Tracker")
        #expect(names["/p/ios/Baby Tracker"] == "ios/Baby Tracker")
        #expect(names["/p/Site"] == "Site")
    }
}

@Suite struct ReportTests {
    @Test func projectLabelStaysTheSameInEveryPeriod() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(
            reply(id: "old", cwd: "/p/web/Tracker", timestamp: "2026-01-01T12:00:00Z"),
            to: "-p-web-Tracker/a.jsonl"
        )
        _ = try sandbox.write(
            reply(id: "new", cwd: "/p/ios/Tracker", timestamp: "2026-11-03T12:00:00Z"),
            to: "-p-ios-Tracker/b.jsonl"
        )
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        let cutoff = try Date("2026-11-01T00:00:00Z", strategy: .iso8601)
        #expect(try store.report(by: .project, since: cutoff).map(\.label) == ["ios/Tracker"])
    }

    @Test func groupsAndFiltersByDate() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(
            reply(id: "a", model: "opus", timestamp: "2026-11-01T12:00:00Z")
                + reply(id: "b", model: "opus", timestamp: "2026-11-03T12:00:00.500Z")
                + reply(id: "c", model: "sonnet", timestamp: "2026-11-03T13:00:00Z"),
            to: "\(appFolder)/session.jsonl"
        )
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()

        let models = try store.report(by: .model)
        #expect(models.map(\.label) == ["opus", "sonnet"])
        #expect(models[0].totals.replies == 2)

        let days = try store.report(by: .day)
        #expect(days.count == 2)
        #expect(days[0].label > days[1].label)

        let cutoff = try Date("2026-11-02T00:00:00Z", strategy: .iso8601)
        #expect(try store.totals(since: cutoff).replies == 2)
    }
}

@Suite struct CostTests {
    private func reply(
        id: String, model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0,
        read: Int = 0, write5m: Int = 0, write1h: Int = 0, speed: String = "standard",
        timestamp: String = "2026-11-04T12:00:00.000Z"
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"/Users/me/Projects/App","sessionId":"s1",\
        "message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(write5m + write1h),"cache_read_input_tokens":\(read),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)},\
        "speed":"\(speed)"}}}

        """
    }

    private func cost(of lines: String) throws -> CostSummary {
        let sandbox = try Sandbox()
        _ = try sandbox.write(lines, to: "\(appFolder)/s.jsonl")
        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()
        return try store.cost()
    }

    @Test func eachKindOfTokenHasItsOwnPrice() throws {
        let million = 1_000_000
        // $4 input + $20 output + $0.20 read + $5 five-minute write + $8 one-hour write.
        let summary = try cost(of: reply(
            id: "a", input: million, output: million, read: million, write5m: million, write1h: million
        ))
        #expect(abs(summary.usd - 37.2) < 0.0001)
    }

    @Test func matchesTheCostClaudeCodeRecordedForARealSession() throws {
        // Token counts and the $32.9605 total are from a real Claude Sonnet 5 session.
        let summary = try cost(of: reply(
            id: "a", model: "claude-sonnet-5", input: 10378, output: 338_022,
            read: 125_945_302, write1h: 1_092_609
        ))
        #expect(abs(summary.usd - 32.9605) < 0.001)
    }

    @Test func aDatedModelNameUsesItsFamilyPrice() throws {
        let summary = try cost(of: reply(id: "a", model: "claude-haiku-4-5-20251001", input: 1_000_000))
        #expect(abs(summary.usd - 1) < 0.0001)
    }

    @Test func longHaikuPromptsCostFiveTimesAsMuch() throws {
        let short = try cost(of: reply(id: "a", model: "claude-haiku-5-5", input: 100_000))
        #expect(abs(short.usd - 0.01) < 0.0001)
        let long = try cost(of: reply(id: "a", model: "claude-haiku-5-5", input: 100_001))
        #expect(abs(long.usd - 0.05) < 0.0001)
    }

    @Test func fastModeCostsTwiceAsMuch() throws {
        let summary = try cost(of: reply(id: "a", output: 1_000_000, speed: "fast"))
        #expect(abs(summary.usd - 40) < 0.0001)
    }

    @Test func unknownModelsAreCountedButNotPriced() throws {
        let summary = try cost(of: reply(id: "a", model: "new-model", input: 1_000_000) + reply(id: "b", input: 1_000_000))
        #expect(abs(summary.usd - 4) < 0.0001)
        #expect(summary.unpricedReplies == 1)
    }

    @Test func logsWithoutWriteDetailCountAsOneHour() throws {
        let line = CoreLine.withoutWriteDetail
        let summary = try cost(of: line)
        #expect(abs(summary.usd - 8) < 0.0001)
    }

    @Test func aDatabaseFromAnEarlierVersionIsFilledInFromTheLogs() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write(reply(id: "a", write5m: 1_000_000), to: "\(appFolder)/s.jsonl")

        // Recreate the earlier layout: no cost columns, and the log already marked as read.
        let old = try Database(url: sandbox.locations.database)
        try old.execute("""
            CREATE TABLE responses (
                message_id TEXT PRIMARY KEY, source TEXT NOT NULL, session_id TEXT, project TEXT NOT NULL,
                model TEXT NOT NULL, ts INTEGER NOT NULL, is_subagent INTEGER NOT NULL, input INTEGER NOT NULL,
                output INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL
            ) WITHOUT ROWID;
            INSERT INTO responses VALUES ('a', 'claude_code', 's1', '/p', 'claude-opus-5-5', 1793793600, 0, 0, 0, 1000000, 0);
            CREATE TABLE log_files (path TEXT PRIMARY KEY, file_id INTEGER NOT NULL, next_offset INTEGER NOT NULL) WITHOUT ROWID;
            INSERT INTO log_files VALUES ('\(sandbox.locations.claudeCodeProjects.path)/\(appFolder)/s.jsonl', 1, 999999);
            """)

        let store = try UsageStore(locations: sandbox.locations)
        try store.sync()
        #expect(abs(try store.cost().usd - 5) < 0.0001)
        #expect(try store.totals().replies == 1)
    }

    @Test func theDashboardShowsEachPeriodSeparately() async throws {
        let sandbox = try Sandbox()
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        let stamp = { (date: Date) in date.formatted(.iso8601) }
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
        _ = try sandbox.write(
            reply(id: "session", input: 1_000_000, timestamp: stamp(now.addingTimeInterval(-3600)))
                + reply(id: "today", input: 1_000_000, timestamp: stamp(now.addingTimeInterval(-3 * 3600)))
                + reply(id: "week", input: 1_000_000, timestamp: stamp(now.addingTimeInterval(-2 * 86400)))
                + reply(id: "month", input: 1_000_000, timestamp: stamp(now.addingTimeInterval(-10 * 86400)))
                + reply(id: "old", input: 1_000_000, timestamp: stamp(lastMonth)),
            to: "\(appFolder)/s.jsonl"
        )
        let t = Int64(now.timeIntervalSince1970)
        let line = #"{"t":\#(t),"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":\#(t + 3 * 3600)},"seven_day":{"used_percentage":12,"resets_at":\#(t + 4 * 86400)}}}"# + "\n"
        try FileManager.default.createDirectory(at: sandbox.locations.dataDirectory, withIntermediateDirectories: true)
        try Data(line.utf8).write(to: sandbox.locations.dataDirectory.appendingPathComponent("readings.jsonl"))

        let dashboard = try await DashboardEngine(locations: sandbox.locations).load(now: now)
        #expect(dashboard.costs.map(\.title) == ["Session", "Today", "7 days", "30 days"])
        #expect(dashboard.costs.map { $0.usd.map { Int($0.rounded()) } } == [4, 8, 12, 16])
    }

    @Test func thereIsNoSessionCostWithoutACurrentSession() async throws {
        let sandbox = try Sandbox()
        let dashboard = try await DashboardEngine(locations: sandbox.locations).load()
        #expect(dashboard.costs.first?.usd == nil)
    }
}

private enum CoreLine {
    static let withoutWriteDetail = """
        {"type":"assistant","timestamp":"2026-11-04T12:00:00.000Z","cwd":"/Users/me/Projects/App","sessionId":"s1",\
        "message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,\
        "cache_creation_input_tokens":1000000,"cache_read_input_tokens":0}}}

        """
}

@Suite struct CurrencyTests {
    private let feed = Data("""
        <gesmes:Envelope><Cube><Cube time='2026-11-04'>
        <Cube currency='USD' rate='1.25'/><Cube currency='GBP' rate='0.75'/>
        </Cube></Cube></gesmes:Envelope>
        """.utf8)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let portugal = Locale(identifier: "en_US@rg=ptzzzz")

    @Test func dollarsAreConvertedThroughTheEuroRate() throws {
        let rates = try #require(ExchangeRates.parse(feed, fetchedAt: now))
        #expect(rates.date == "2026-11-04")
        let euros = try #require(rates.format(for: "EUR"))
        #expect(abs(euros.perUSD - 0.8) < 0.0001)
        let pounds = try #require(rates.format(for: "GBP"))
        #expect(abs(pounds.perUSD - 0.6) < 0.0001)
        #expect(rates.format(for: "USD") == .usd)
    }

    @Test func aCurrencyTheBankDoesntListStaysInDollars() throws {
        let rates = try #require(ExchangeRates.parse(feed, fetchedAt: now))
        #expect(rates.format(for: "XYZ") == nil)
    }

    @Test func aBadFeedIsIgnored() {
        #expect(ExchangeRates.parse(Data("<html>Maintenance</html>".utf8), fetchedAt: now) == nil)
    }

    @Test func amountsShowTheConvertedValueAndSymbol() {
        let euros = MoneyFormat(code: "EUR", perUSD: 0.8, rateDate: "2026-11-04")
        let text = euros.plain(10)
        #expect(text.contains("€") && text.contains("8"))
        #expect(!text.contains("$"))
        #expect(euros.approximate(1000).contains("800"))
        #expect(euros.conversionNote?.contains("2026-11-04") == true)
        #expect(MoneyFormat.usd.conversionNote == nil)
    }

    @Test func ratesAreSavedAndUsedForThisRegion() async throws {
        let sandbox = try Sandbox()
        #expect(MoneyFormat.current(locations: sandbox.locations, locale: portugal) == .usd)

        let engine = try DashboardEngine(locations: sandbox.locations)
        let feed = feed
        #expect(await engine.updateExchangeRates(now: now, locale: portugal, fetch: { _ in feed }))

        let money = MoneyFormat.current(locations: sandbox.locations, locale: portugal)
        #expect(money.code == "EUR")
        #expect(abs(money.perUSD - 0.8) < 0.0001)
    }

    @Test func ratesAreOnlyFetchedOnceADayAndNeverForDollars() async throws {
        let sandbox = try Sandbox()
        let engine = try DashboardEngine(locations: sandbox.locations)
        let feed = feed
        let fails: @Sendable (URL) async throws -> Data = { _ in throw CocoaError(.fileReadUnknown) }

        let america = Locale(identifier: "en_US")
        #expect(await engine.updateExchangeRates(now: now, locale: america, fetch: { _ in feed }) == false)

        #expect(await engine.updateExchangeRates(now: now, locale: portugal, fetch: { _ in feed }))
        let soon = now.addingTimeInterval(23 * 3600)
        #expect(await engine.updateExchangeRates(now: soon, locale: portugal, fetch: { _ in feed }) == false)
        let tomorrow = now.addingTimeInterval(25 * 3600)
        #expect(await engine.updateExchangeRates(now: tomorrow, locale: portugal, fetch: fails) == false)

        // A failed download keeps the old rate, and waits an hour before trying again.
        #expect(MoneyFormat.current(locations: sandbox.locations, locale: portugal).code == "EUR")
        let later = tomorrow.addingTimeInterval(30 * 60)
        #expect(await engine.updateExchangeRates(now: later, locale: portugal, fetch: { _ in feed }) == false)
        let hourLater = tomorrow.addingTimeInterval(3601)
        #expect(await engine.updateExchangeRates(now: hourLater, locale: portugal, fetch: { _ in feed }))
    }
}
