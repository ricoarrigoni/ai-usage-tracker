import Foundation

/// The token counts for one line of a log. Message text is never decoded or kept.
public struct UsageRecord: Equatable, Sendable {
    public var messageID: String
    public var sessionID: String?
    public var model: String
    public var timestamp: Int64
    public var cwd: String?
    public var isSubagent: Bool
    public var input: Int64
    public var output: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64
}

public enum ParsedLine: Equatable, Sendable {
    case record(UsageRecord)
    /// Not a usage line, such as a user message that happens to contain the word "usage".
    case ignored
    /// Looks like a usage line but can't be read, which may mean the log format changed.
    case unrecognized
}

enum LineParser {
    /// Lines without this text can't hold usage, so they are skipped without parsing.
    static let marker = Data("\"usage\"".utf8)

    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var cwd: String?
        var sessionId: String?
        var isSidechain: Bool?
        var message: Message?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, cwd, sessionId, isSidechain, message
        }

        // Fields can have other shapes on other line types, and that shouldn't fail the whole line.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
            isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        }
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct Usage: Decodable {
        var input_tokens: Int64?
        var output_tokens: Int64?
        var cache_creation_input_tokens: Int64?
        var cache_read_input_tokens: Int64?
    }

    static func parse(_ data: Data) -> ParsedLine {
        guard let line = try? JSONDecoder().decode(Line.self, from: data) else { return .unrecognized }
        guard line.type == "assistant" else { return .ignored }
        guard let message = line.message, let usage = message.usage else { return .ignored }
        // Claude Code writes placeholder replies with this model that used no tokens.
        if message.model == "<synthetic>" { return .ignored }
        guard
            let id = message.id,
            let model = message.model,
            let timestamp = line.timestamp.flatMap(parseDate),
            let input = usage.input_tokens,
            let output = usage.output_tokens
        else { return .unrecognized }

        return .record(UsageRecord(
            messageID: id,
            sessionID: line.sessionId,
            model: model,
            timestamp: timestamp,
            cwd: line.cwd,
            isSubagent: line.isSidechain ?? false,
            input: input,
            output: output,
            cacheWrite: usage.cache_creation_input_tokens ?? 0,
            cacheRead: usage.cache_read_input_tokens ?? 0
        ))
    }

    private static func parseDate(_ text: String) -> Int64? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(text) { return Int64(date.timeIntervalSince1970) }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return Int64(date.timeIntervalSince1970) }
        return nil
    }
}
