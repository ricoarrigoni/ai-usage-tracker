import Foundation

/// The app's own copy of usage numbers. Rows stay here after Claude Code deletes the original logs.
public final class UsageStore {
    public static let coworkProject = "Cowork"

    public enum Source: String, Sendable {
        case claudeCode = "claude_code"
        case cowork
    }

    public struct SyncSummary: Equatable, Sendable {
        public var filesFound = 0
        public var filesRead = 0
        public var unrecognizedLines = 0
    }

    let database: Database
    private let locations: Locations

    public init(locations: Locations) throws {
        self.locations = locations
        database = try Database(url: locations.database)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS responses (
                message_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                session_id TEXT,
                project TEXT NOT NULL,
                model TEXT NOT NULL,
                ts INTEGER NOT NULL,
                is_subagent INTEGER NOT NULL,
                input INTEGER NOT NULL,
                output INTEGER NOT NULL,
                cache_write INTEGER NOT NULL,
                cache_read INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS responses_ts ON responses (ts);
            CREATE TABLE IF NOT EXISTS limit_readings (
                session TEXT NOT NULL,
                ts INTEGER NOT NULL,
                five_pct REAL,
                five_resets INTEGER,
                seven_pct REAL,
                seven_resets INTEGER,
                cost REAL,
                PRIMARY KEY (session, ts)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS log_files (
                path TEXT PRIMARY KEY,
                file_id INTEGER NOT NULL,
                next_offset INTEGER NOT NULL
            ) WITHOUT ROWID;
            """)
        try createAlertTable()
    }

    /// Reads whatever is new in the logs. Safe to run at any time, as often as you like.
    @discardableResult
    public func sync() throws -> SyncSummary {
        var summary = SyncSummary()
        for log in discoverLogs() {
            summary.filesFound += 1
            do {
                summary.unrecognizedLines += try syncFile(log, summary: &summary)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                // Claude Code can delete a log while this runs. What's already saved stays saved.
                continue
            }
        }
        return summary
    }

    private struct LogFile {
        var url: URL
        var source: Source
        var folderName: String
    }

    private func discoverLogs() -> [LogFile] {
        var logs: [LogFile] = []
        let manager = FileManager.default

        let root = locations.claudeCodeProjects.standardizedFileURL.pathComponents.count
        if let files = manager.enumerator(at: locations.claudeCodeProjects, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "jsonl" {
                let parts = url.standardizedFileURL.pathComponents
                guard parts.count > root else { continue }
                logs.append(LogFile(url: url, source: .claudeCode, folderName: parts[root]))
            }
        }

        // Cowork keeps each reply in both a transcript and audit.jsonl, so only transcripts are read.
        if let files = manager.enumerator(at: locations.coworkSessions, includingPropertiesForKeys: nil) {
            for case let url as URL in files
            where url.pathExtension == "jsonl" && url.path.contains("/.claude/projects/") {
                logs.append(LogFile(url: url, source: .cowork, folderName: ""))
            }
        }
        return logs
    }

    private func syncFile(_ log: LogFile, summary: inout SyncSummary) throws -> Int {
        let path = log.url.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0

        var offset: Int64 = 0
        var knownFileID: Int64?
        try database.prepare("SELECT file_id, next_offset FROM log_files WHERE path = ?")
            .run([.text(path)]) { row in
                knownFileID = row.int(0)
                offset = row.int(1)
            }

        // A replaced or shortened file is read again from the start. Existing rows are kept.
        if knownFileID != fileID || size < offset { offset = 0 }
        if knownFileID == fileID && size == offset { return 0 }

        summary.filesRead += 1
        return try database.transaction {
            let insert = try database.prepare("""
                INSERT INTO responses
                    (message_id, source, session_id, project, model, ts, is_subagent,
                     input, output, cache_write, cache_read)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (message_id) DO UPDATE SET
                    input = max(input, excluded.input),
                    output = max(output, excluded.output),
                    cache_write = max(cache_write, excluded.cache_write),
                    cache_read = max(cache_read, excluded.cache_read)
                """)
            let output = try LogFileReader.read(log.url, from: offset) { record in
                let project = log.source == .cowork
                    ? Self.coworkProject
                    : ProjectResolver.projectPath(cwd: record.cwd, logFolderName: log.folderName)
                try insert.run([
                    .text(record.messageID),
                    .text(log.source.rawValue),
                    record.sessionID.map { .text($0) } ?? .null,
                    .text(project),
                    .text(record.model),
                    .int(record.timestamp),
                    .int(record.isSubagent ? 1 : 0),
                    .int(record.input),
                    .int(record.output),
                    .int(record.cacheWrite),
                    .int(record.cacheRead),
                ])
            }
            try database.prepare("""
                INSERT INTO log_files (path, file_id, next_offset) VALUES (?, ?, ?)
                ON CONFLICT (path) DO UPDATE SET
                    file_id = excluded.file_id, next_offset = excluded.next_offset
                """).run([.text(path), .int(fileID), .int(output.nextOffset)])
            return output.unrecognizedLines
        }
    }
}
