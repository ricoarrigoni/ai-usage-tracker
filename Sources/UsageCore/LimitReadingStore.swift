import Foundation

extension UsageStore {
    /// Saves new status line readings. A reading that repeats its session's last one is skipped,
    /// because open sessions write the same values every minute.
    public func syncReadings(from file: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0

        var offset: Int64 = 0
        var knownID: Int64?
        try database.prepare("SELECT file_id, next_offset FROM log_files WHERE path = ?")
            .run([.text(file.path)]) { row in
                knownID = row.int(0)
                offset = row.int(1)
            }
        if knownID != fileID || size < offset { offset = 0 }
        if knownID == fileID && size == offset { return }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        let nextOffset = offset + Int64(complete.count)

        let decoder = JSONDecoder()
        let readings = complete.split(separator: 0x0A)
            .compactMap { try? decoder.decode(LimitReading.self, from: Data($0)) }

        try database.transaction {
            let last = try database.prepare("""
                SELECT five_pct, five_resets, seven_pct, seven_resets, cost FROM limit_readings
                WHERE session = ? ORDER BY ts DESC LIMIT 1
                """)
            let insert = try database.prepare("""
                INSERT OR REPLACE INTO limit_readings
                    (session, ts, five_pct, five_resets, seven_pct, seven_resets, cost)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            var latest: [String: StoredValues] = [:]
            for reading in readings {
                let session = reading.session ?? ""
                if latest[session] == nil {
                    try last.run([.text(session)]) { row in
                        latest[session] = StoredValues(
                            fivePercent: row.double(0),
                            fiveResets: row.double(1).map { Int64($0) },
                            sevenPercent: row.double(2),
                            sevenResets: row.double(3).map { Int64($0) },
                            cost: row.double(4)
                        )
                    }
                }
                let five = reading.rate_limits?.five_hour
                let seven = reading.rate_limits?.seven_day
                let values = StoredValues(
                    fivePercent: five?.used_percentage,
                    fiveResets: five?.resets_at,
                    sevenPercent: seven?.used_percentage,
                    sevenResets: seven?.resets_at,
                    cost: reading.cost_usd
                )
                if latest[session] == values { continue }
                latest[session] = values
                try insert.run([
                    .text(session),
                    .int(reading.t),
                    values.fivePercent.map { .double($0) } ?? .null,
                    values.fiveResets.map { .int($0) } ?? .null,
                    values.sevenPercent.map { .double($0) } ?? .null,
                    values.sevenResets.map { .int($0) } ?? .null,
                    values.cost.map { .double($0) } ?? .null,
                ])
            }
            try database.prepare("""
                INSERT INTO log_files (path, file_id, next_offset) VALUES (?, ?, ?)
                ON CONFLICT (path) DO UPDATE SET
                    file_id = excluded.file_id, next_offset = excluded.next_offset
                """).run([.text(file.path), .int(fileID), .int(nextOffset)])
        }
    }

    public func allReadings() throws -> [LimitReading] {
        var readings: [LimitReading] = []
        try database.prepare("""
            SELECT session, ts, five_pct, five_resets, seven_pct, seven_resets, cost
            FROM limit_readings ORDER BY ts
            """).run { row in
            func window(_ percent: Int32, _ resets: Int32) -> LimitReading.Window? {
                guard let value = row.double(percent), let end = row.double(resets) else { return nil }
                return .init(used_percentage: value, resets_at: Int64(end))
            }
            readings.append(LimitReading(
                t: row.int(1),
                session: row.text(0),
                cost_usd: row.double(6),
                rate_limits: .init(five_hour: window(2, 3), seven_day: window(4, 5))
            ))
        }
        return readings
    }

    private struct StoredValues: Equatable {
        var fivePercent: Double?
        var fiveResets: Int64?
        var sevenPercent: Double?
        var sevenResets: Int64?
        var cost: Double?
    }
}
