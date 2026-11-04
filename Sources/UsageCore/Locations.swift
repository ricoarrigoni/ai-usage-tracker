import Foundation

/// Where logs are read from and where the app keeps its own data.
public struct Locations: Sendable {
    public var dataDirectory: URL
    public var claudeCodeProjects: URL
    public var coworkSessions: URL

    public init(dataDirectory: URL, claudeCodeProjects: URL, coworkSessions: URL) {
        self.dataDirectory = dataDirectory
        self.claudeCodeProjects = claudeCodeProjects
        self.coworkSessions = coworkSessions
    }

    public var database: URL { dataDirectory.appendingPathComponent("usage.sqlite") }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Locations {
        let support = home.appendingPathComponent("Library/Application Support")
        let data = environment["AI_USAGE_TRACKER_DIR"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("AIUsageTracker")
        let claudeConfig = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return Locations(
            dataDirectory: data,
            claudeCodeProjects: claudeConfig.appendingPathComponent("projects"),
            coworkSessions: support.appendingPathComponent("Claude/local-agent-mode-sessions")
        )
    }
}
