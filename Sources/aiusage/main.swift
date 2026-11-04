import Foundation
import UsageCore

let usage = """
    Shows your Claude token usage, from logs on this Mac.

    Usage:
      aiusage                     Today, the last 7 and 30 days, and everything recorded
      aiusage --by day            Group by day, project, model or source
      aiusage --by project --days 7
      aiusage sync                Read new logs and report what was read

    Options:
      --by <day|project|model|source>
      --days <n>                  Only the last n days, including today
      --json                      Exact numbers as JSON
      --no-sync                   Don't read new logs first

    Not included: chat, Cowork with no logs on this Mac, background requests Claude Code
    doesn't log, and logs deleted before the first sync.
    """

struct Options {
    var grouping: Grouping?
    var days: Int?
    var json = false
    var sync = true
    var syncOnly = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aiusage: \(message)\n".utf8))
    exit(1)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "sync": options.syncOnly = true
        case "--json": options.json = true
        case "--no-sync": options.sync = false
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--by":
            guard let value = remaining.popFirst(), let grouping = Grouping(rawValue: value) else {
                fail("--by needs one of: day, project, model, source")
            }
            options.grouping = grouping
        case "--days":
            guard let value = remaining.popFirst(), let days = Int(value), days > 0 else {
                fail("--days needs a number above 0")
            }
            options.days = days
        default:
            fail("unknown option \(argument). Run aiusage --help")
        }
    }
    return options
}

/// The start of the local day, `days` days back, counting today as the first.
func startDate(days: Int) -> Date {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
}

func short(_ number: Int64) -> String { TokenFormat.short(number) }

func printTable(firstColumn: String, rows: [ReportRow]) {
    let headers = [firstColumn, "Replies", "Input", "Output", "Cache write", "Cache read", "Total"]
    let body = rows.map { row in
        [row.label, String(row.totals.replies), short(row.totals.input), short(row.totals.output),
         short(row.totals.cacheWrite), short(row.totals.cacheRead), short(row.totals.total)]
    }
    let table = [headers] + body
    let widths = headers.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
    for line in table {
        let cells = line.enumerated().map { column, text in
            let padding = String(repeating: " ", count: widths[column] - text.count)
            return column == 0 ? text + padding : padding + text
        }
        print(cells.joined(separator: "  "))
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

do {
    let store = try UsageStore(locations: .standard())

    if options.sync || options.syncOnly {
        let summary = try store.sync()
        if summary.unrecognizedLines > 0 {
            let warning = "aiusage: warning: skipped \(summary.unrecognizedLines) log lines it couldn't read. "
                + "The log format may have changed, so totals could be low.\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        if options.syncOnly {
            print("Found \(summary.filesFound) log files and read new data from \(summary.filesRead).")
            exit(0)
        }
    }

    let since = options.days.map(startDate)
    if let grouping = options.grouping {
        let rows = try store.report(by: grouping, since: since)
        if options.json {
            try printJSON(rows)
        } else {
            printTable(firstColumn: grouping.rawValue.capitalized, rows: rows)
        }
    } else {
        var periods = [
            ReportRow(label: "Today", totals: try store.totals(since: startDate(days: 1))),
            ReportRow(label: "Last 7 days", totals: try store.totals(since: startDate(days: 7))),
            ReportRow(label: "Last 30 days", totals: try store.totals(since: startDate(days: 30))),
        ]
        periods.append(ReportRow(label: "All recorded", totals: try store.totals()))
        if options.json {
            try printJSON(periods)
        } else {
            printTable(firstColumn: "Period", rows: periods)
            print("\nNot included: chat, Cowork with no logs on this Mac, background requests Claude Code doesn't log,")
            print("and logs deleted before the first sync.")
        }
    }
} catch {
    fail("\(error)")
}
