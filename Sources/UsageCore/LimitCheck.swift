import Foundation

/// Asks Claude Code for the current limits, so they can be refreshed without using Claude Code.
///
/// It runs the installed `claude` command in print mode with Claude Code's own `/usage` command,
/// which sends no message to Claude and reports every limit, including weekly limits for single
/// models such as Fable. If that output can't be read, it falls back to a one-word message on the
/// smallest model, whose output also carries the session and weekly limits but uses a very small
/// part of the session limit. Both run with no MCP servers or settings and save nothing to Claude
/// Code's history. Claude Code handles the login itself; this app never sees it.
public enum LimitCheck {
    /// The session name written with each check's reading, so it can be told apart from status line readings.
    public static let session = "refresh-button"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case claudeNotFound
        case timedOut
        case noLimits(String?)

        public var description: String {
            switch self {
            case .claudeNotFound:
                "Couldn't find Claude Code on this Mac, so limits can't be checked."
            case .timedOut:
                "Claude Code didn't answer in time. Try again in a moment."
            case .noLimits(let detail):
                "Claude Code didn't report limits" + (detail.map { ": \($0)" } ?? ".")
            }
        }
    }

    static let usageArguments = [
        "-p", "/usage",
        "--output-format", "json",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--setting-sources", "",
    ]

    static let messageArguments = [
        "-p", "Reply with OK",
        "--model", "haiku",
        "--output-format", "stream-json", "--verbose",
        "--no-session-persistence",
        "--tools", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--setting-sources", "",
    ]

    /// Runs the check and saves its reading where status line readings go.
    public static func run(locations: Locations = .standard(), timeout: TimeInterval = 60) async throws {
        guard let claude = findClaude() else { throw Failure.claudeNotFound }
        let usage = try await launch(claude, arguments: usageArguments, timeout: timeout)
        let reading: LimitReading
        if let fromUsage = parseUsage(usage, now: Date()) {
            reading = fromUsage
        } else {
            let output = try await launch(claude, arguments: messageArguments, timeout: timeout)
            reading = try parse(output, at: Int64(Date().timeIntervalSince1970))
        }
        try append(reading, to: locations.dataDirectory.appendingPathComponent("readings.jsonl"))
    }

    // MARK: Finding Claude Code

    /// Apps opened from the Finder don't get the shell's PATH, so the usual install places are checked
    /// first, then the login shell is asked.
    static func findClaude(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let files = FileManager.default
        func runnable(_ path: String) -> URL? {
            files.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }

        var candidates = [
            ".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude",
            ".volta/bin/claude",
        ].map { home.appendingPathComponent($0).path }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        // nvm keeps one folder per Node version; prefer the newest.
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? files.contentsOfDirectory(atPath: nvm.path) {
            candidates += versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { nvm.appendingPathComponent("\($0)/bin/claude").path }
        }
        for path in candidates {
            if let found = runnable(path) { return found }
        }

        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.hasPrefix("/") ? runnable(line) : nil
    }

    // MARK: Running it

    private static func launch(_ claude: URL, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        // An npm install of Claude Code needs `node`, which sits next to it.
        var environment = ProcessInfo.processInfo.environment
        let folders = [claude.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (folders + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collected = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            collected.add(handle.availableData)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let finish = Once()
            process.terminationHandler = { _ in
                output.fileHandleForReading.readabilityHandler = nil
                collected.add(output.fileHandleForReading.readDataToEndOfFile())
                finish.run { continuation.resume(returning: collected.data) }
            }
            do {
                try process.run()
            } catch {
                finish.run { continuation.resume(throwing: Failure.claudeNotFound) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                finish.run { continuation.resume(throwing: Failure.timedOut) }
            }
        }
    }

    // MARK: Reading /usage

    /// Reads the text `/usage` prints, such as
    /// "Current session: 10% used · resets Nov 15 at 5:20am (Europe/Madrid)" and
    /// "Current week (Fable): 9% used · resets Nov 18 at 7pm (Europe/Madrid)".
    /// Percentages there are rounded to the nearest point, like the Claude apps. Returns nil when
    /// neither the session nor the week can be read, so the caller can fall back.
    static func parseUsage(_ output: Data, now: Date) -> LimitReading? {
        struct Result: Decodable { var result: String?; var is_error: Bool? }
        guard let decoded = try? JSONDecoder().decode(Result.self, from: output),
              decoded.is_error != true, let text = decoded.result
        else { return nil }
        return parseUsageText(text, now: now)
    }

    static func parseUsageText(_ text: String, now: Date) -> LimitReading? {
        let pattern = #/^\s*Current (?:session|week \((?<scope>[^)]+)\)):\s*(?<percent>\d+(?:\.\d+)?)% used(?:\s*·\s*resets (?<resets>.+))?\s*$/#
        var limits = LimitReading.Limits()
        var models: [String: LimitReading.Window] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = try? pattern.wholeMatch(in: String(line)),
                  let percent = Double(match.percent)
            else { continue }
            let resets = match.resets.flatMap { resetDate(String($0), now: now) }
            let window = LimitReading.Window(
                used_percentage: percent, resets_at: resets.map { Int64($0.timeIntervalSince1970) }
            )
            switch match.scope.map(String.init) {
            case nil: limits.five_hour = window
            case "all models"?: limits.seven_day = window
            case let model?: models[model] = window
            }
        }
        guard limits.five_hour != nil || limits.seven_day != nil else { return nil }
        return LimitReading(
            t: Int64(now.timeIntervalSince1970), session: session, rate_limits: limits,
            model_weeks: models.isEmpty ? nil : models
        )
    }

    /// Reads "Nov 18 at 7pm (Europe/Madrid)" or "5:20am (Europe/Madrid)". The year isn't printed,
    /// so it's the one that puts the date nearest to now.
    static func resetDate(_ text: String, now: Date) -> Date? {
        let pattern = #/^(?:(?<month>[A-Za-z]{3})[a-z]* (?<day>\d{1,2})(?:,? \d{4})? at )?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<half>am|pm)(?:\s*\((?<zone>[^)]+)\))?/#
        guard let match = try? pattern.ignoresCase().prefixMatch(in: text.trimmingCharacters(in: .whitespaces))
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        let zoneName = match.zone.map(String.init)
        calendar.timeZone = zoneName.flatMap { name in
            TimeZone(identifier: name) ?? TimeZone(identifier: name.capitalized)
        } ?? .current

        guard var hour = Int(match.hour), hour <= 12 else { return nil }
        if hour == 12 { hour = 0 }
        if match.half.lowercased() == "pm" { hour += 12 }
        let minute = match.minute.flatMap { Int($0) } ?? 0

        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        if let month = match.month {
            let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let index = names.firstIndex(of: month.lowercased()), let day = match.day.flatMap({ Int($0) })
            else { return nil }
            parts.month = index + 1
            parts.day = day
        }
        parts.hour = hour
        parts.minute = minute

        guard let date = calendar.date(from: parts) else { return nil }
        if match.month == nil {
            // A time alone is the next time it comes around.
            return date < now.addingTimeInterval(-60) ? calendar.date(byAdding: .day, value: 1, to: date) : date
        }
        // Dates printed without a year: a reset is never far off, so pick the nearest year.
        let candidates = [-1, 0, 1].compactMap { calendar.date(byAdding: .year, value: $0, to: date) }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    // MARK: Reading the message check's answer

    private struct Event: Decodable {
        struct Info: Decodable {
            struct Window: Decodable {
                var utilization: Double?
                var resetsAt: Int64?
            }
            var unifiedWindows: [String: Window]?
        }
        var type: String?
        var rate_limit_info: Info?
        var result: String?
        var is_error: Bool?
    }

    /// Turns Claude Code's output into a reading. Utilization comes as a fraction; it's stored as a
    /// whole percentage rounded down, the same way the status line reports it.
    static func parse(_ output: Data, at time: Int64) throws -> LimitReading {
        let decoder = JSONDecoder()
        var limits = LimitReading.Limits()
        var found = false
        var errorText: String?
        for line in output.split(separator: 0x0A) {
            guard let event = try? decoder.decode(Event.self, from: Data(line)) else { continue }
            if event.type == "result", event.is_error == true { errorText = event.result }
            guard event.type == "rate_limit_event", let windows = event.rate_limit_info?.unifiedWindows else { continue }
            func window(_ key: String) -> LimitReading.Window? {
                guard let value = windows[key], let used = value.utilization, let resets = value.resetsAt else { return nil }
                return .init(used_percentage: (used * 100 + 1e-6).rounded(.down), resets_at: resets)
            }
            if let five = window(LimitKind.fiveHour.rawValue) { limits.five_hour = five; found = true }
            if let seven = window(LimitKind.sevenDay.rawValue) { limits.seven_day = seven; found = true }
        }
        guard found else {
            let detail = errorText?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.noLimits(detail.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) })
        }
        return LimitReading(t: time, session: session, rate_limits: limits)
    }

    static func append(_ reading: LimitReading, to file: URL) throws {
        struct Line: Encodable {
            var t: Int64
            var session: String?
            var cost_usd: Double?
            var rate_limits: LimitReading.Limits?
            var model_weeks: [String: LimitReading.Window]?
        }
        var data = try JSONEncoder().encode(Line(
            t: reading.t, session: reading.session, cost_usd: nil, rate_limits: reading.rate_limits,
            model_weeks: reading.model_weeks
        ))
        data.append(0x0A)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func add(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }
    var data: Data { lock.withLock { buffer } }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ action: () -> Void) {
        let first = lock.withLock { () -> Bool in
            if done { return false }
            done = true
            return true
        }
        if first { action() }
    }
}
