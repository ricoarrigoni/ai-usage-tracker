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
