import Foundation

/// Reads a log from a byte offset, one complete line at a time.
enum LogFileReader {
    struct Output {
        /// Where the next read should start. Stops before an unfinished last line.
        var nextOffset: Int64
        var unrecognizedLines: Int
    }

    static func read(
        _ url: URL,
        from offset: Int64,
        onRecord: (UsageRecord) throws -> Void
    ) throws -> Output {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var nextOffset = offset
        var unrecognized = 0
        var buffer = Data()

        func process(_ line: Data) throws {
            guard line.range(of: LineParser.marker) != nil else { return }
            switch LineParser.parse(line) {
            case .record(let record): try onRecord(record)
            case .ignored: break
            case .unrecognized: unrecognized += 1
            }
        }

        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                try process(Data(buffer[start..<newline]))
                start = buffer.index(after: newline)
            }
            nextOffset += Int64(start - buffer.startIndex)
            buffer = Data(buffer[start...])
        }

        // A last line with no newline may still be being written. Use it if it's already complete,
        // but read it again next time. Saving a usage line twice is harmless.
        if !buffer.isEmpty, case .record(let record) = LineParser.parse(buffer) {
            try onRecord(record)
        }
        return Output(nextOffset: nextOffset, unrecognizedLines: unrecognized)
    }
}
