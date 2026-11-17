import Foundation

public struct AccessLog: Identifiable {
    public var id: Int64
    public var toolName: String
    public var createdAt: Date
    public var resultCount: Int
}

public final class RecordRepository {
    public let database: SQLiteDatabase
    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try database.executeScript("""
        CREATE TABLE IF NOT EXISTS records (
            id TEXT PRIMARY KEY, category TEXT NOT NULL, captured_at TEXT NOT NULL,
            timezone TEXT NOT NULL, payload_json TEXT NOT NULL, media_path TEXT,
            thumbnail_path TEXT, preview_path TEXT, media_sha256 TEXT,
            updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL DEFAULT 0,
            dirty INTEGER NOT NULL DEFAULT 1, source TEXT NOT NULL DEFAULT 'manual', restored_from TEXT
        );
        CREATE INDEX IF NOT EXISTS records_timeline ON records(deleted_at, captured_at DESC);
        CREATE INDEX IF NOT EXISTS records_revision ON records(revision);
        CREATE TABLE IF NOT EXISTS sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS agent_logs(id INTEGER PRIMARY KEY AUTOINCREMENT, tool_name TEXT NOT NULL, client_id TEXT NOT NULL, created_at TEXT NOT NULL, result_count INTEGER NOT NULL);
        """)
        let columns = try database.query("PRAGMA table_info(records)").compactMap { $0["name"]?.text }
        if !columns.contains("source") {
            try database.execute("ALTER TABLE records ADD COLUMN source TEXT NOT NULL DEFAULT 'manual'")
        }
        if !columns.contains("restored_from") {
            try database.execute("ALTER TABLE records ADD COLUMN restored_from TEXT")
        }
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return try? Self.timestamp.parse(string)
    }
    private func string(_ date: Date?) -> String? { date?.formatted(Self.timestamp) }

    private func decode(_ row: SQLiteRow) throws -> LifeRecord {
        guard let id = row["id"]?.text, let categoryString = row["category"]?.text, let category = Category(rawValue: categoryString),
              let capturedAt = date(row["captured_at"]?.text), let timezone = row["timezone"]?.text,
              let payloadData = row["payload_json"]?.text?.data(using: .utf8), let updatedAt = date(row["updated_at"]?.text) else {
            throw ShakeError.invalidRecord
        }
        let payload = try JSONDecoder().decode(RecordPayload.self, from: payloadData)
        let media: MediaRefs?
        if let original = row["media_path"]?.text, let thumbnail = row["thumbnail_path"]?.text, let preview = row["preview_path"]?.text {
            media = MediaRefs(original: original, thumbnail: thumbnail, preview: preview, originalSHA256: row["media_sha256"]?.text)
        } else { media = nil }
        return LifeRecord(id: id, category: category, capturedAt: capturedAt, timezone: timezone, payload: payload, media: media,
                          updatedAt: updatedAt, deletedAt: date(row["deleted_at"]?.text), revision: row["revision"]?.integer ?? 0,
                          dirty: (row["dirty"]?.integer ?? 0) == 1, source: RecordSource(rawValue: row["source"]?.text ?? "") ?? .manual,
                          restoredFrom: date(row["restored_from"]?.text))
    }

    public func save(_ record: LifeRecord) throws {
        let payload = try JSONEncoder().encode(record.payload)
        guard let payloadString = String(data: payload, encoding: .utf8) else { throw ShakeError.invalidRecord }
        try database.execute("""
        INSERT INTO records(id,category,captured_at,timezone,payload_json,media_path,thumbnail_path,preview_path,media_sha256,updated_at,deleted_at,revision,dirty,source,restored_from)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET category=excluded.category,captured_at=excluded.captured_at,timezone=excluded.timezone,
        payload_json=excluded.payload_json,media_path=excluded.media_path,thumbnail_path=excluded.thumbnail_path,preview_path=excluded.preview_path,
        media_sha256=excluded.media_sha256,updated_at=excluded.updated_at,deleted_at=excluded.deleted_at,revision=excluded.revision,dirty=excluded.dirty,source=excluded.source,restored_from=excluded.restored_from
        """, [
            .text(record.id), .text(record.category.rawValue), .text(string(record.capturedAt)!), .text(record.timezone), .text(payloadString),
            .string(record.media?.original), .string(record.media?.thumbnail), .string(record.media?.preview), .string(record.media?.originalSHA256),
            .text(string(record.updatedAt)!), .string(string(record.deletedAt)), .integer(record.revision), .integer(record.dirty ? 1 : 0), .text(record.source.rawValue), .string(string(record.restoredFrom))
        ])
    }

    public func get(_ id: String, includeDeleted: Bool = false) throws -> LifeRecord? {
        try database.query("SELECT * FROM records WHERE id=? \(includeDeleted ? "" : "AND deleted_at IS NULL")", [.text(id)]).first.map(decode)
    }

    func existingRecordIDs(_ ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try database.query("SELECT id FROM records WHERE id IN (\(placeholders))", ids.map(SQLiteValue.text))
        return Set(rows.compactMap { $0["id"]?.text })
    }

    public func list(category: Category? = nil, includeDeleted: Bool = false, deletedOnly: Bool = false, capturedFrom: Date? = nil, capturedBefore: Date? = nil, limit: Int = Int.max) throws -> [LifeRecord] {
        try recordRows(category: category, includeDeleted: includeDeleted, deletedOnly: deletedOnly,
                       capturedFrom: capturedFrom, capturedBefore: capturedBefore, limit: limit).map(decode)
    }

    public struct Position: Codable {
        public let timestamp: String
        public let id: String

        fileprivate init(timestamp: String, id: String) {
            self.timestamp = timestamp
            self.id = id
        }
    }

    public func recordPage(category: Category?, capturedFrom: Date?, capturedBefore: Date?,
                           after: Position?, oldestFirst: Bool, limit: Int) throws -> [(record: LifeRecord, position: Position)] {
        try recordRows(category: category, capturedFrom: capturedFrom, capturedBefore: capturedBefore,
                       after: after, oldestFirst: oldestFirst, limit: limit).map { row in
            let record = try decode(row)
            guard let timestamp = row["captured_at"]?.text else { throw ShakeError.invalidRecord }
            return (record, Position(timestamp: timestamp, id: record.id))
        }
    }

    private func recordRows(category: Category?, includeDeleted: Bool = false, deletedOnly: Bool = false,
                            capturedFrom: Date?, capturedBefore: Date?, after: Position? = nil,
                            oldestFirst: Bool = false, limit: Int) throws -> [SQLiteRow] {
        var conditions = deletedOnly ? ["deleted_at > ?"] : (includeDeleted ? [] : ["deleted_at IS NULL"])
        var values: [SQLiteValue] = deletedOnly ? [.text(string(Date.now.addingTimeInterval(-Self.retention))!)] : []
        if let category { conditions.append("category=?"); values.append(.text(category.rawValue)) }
        if let capturedFrom { conditions.append("captured_at >= ?"); values.append(.text(string(capturedFrom)!)) }
        if let capturedBefore { conditions.append("captured_at < ?"); values.append(.text(string(capturedBefore)!)) }
        if let after {
            let comparison = oldestFirst ? ">" : "<"
            conditions.append("(captured_at, id) \(comparison) (?, ?)")
            values += [.text(after.timestamp), .text(after.id)]
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        values.append(.integer(Int64(limit)))
        let direction = oldestFirst ? "ASC" : "DESC"
        return try database.query("SELECT * FROM records \(whereClause) ORDER BY captured_at \(direction), id \(direction) LIMIT ?", values)
    }

    public func recentWeight() throws -> Double? {
        try database.query("SELECT payload_json FROM records WHERE category='weight' AND deleted_at IS NULL ORDER BY captured_at DESC LIMIT 50")
            .compactMap { row -> Double? in
                guard let data = row["payload_json"]?.text?.data(using: .utf8) else { return nil }
                guard let payload = try? JSONDecoder().decode(RecordPayload.self, from: data),
                      payload.weightInherited != true else { return nil }
                return payload.weight
            }.first
    }

    public func softDelete(_ id: String, now: Date = .now) throws {
        try database.transaction {
            guard var record = try get(id) else { return }
            record.deletedAt = now
            record.restoredFrom = nil
            record.updatedAt = now
            record.dirty = true
            try save(record)
        }
    }

    public func restore(_ id: String, now: Date = .now) throws {
        try database.transaction {
            guard var record = try get(id, includeDeleted: true),
                  let deletedAt = record.deletedAt, record.isRecoverableDeletion,
                  now.timeIntervalSince(deletedAt) < Self.retention else { return }
            record.deletedAt = nil
            record.restoredFrom = deletedAt
            record.updatedAt = now
            record.dirty = true
            try save(record)
        }
    }

    public static let retention: TimeInterval = 30 * 86_400

    public func purgeExpired(now: Date = .now) throws -> [LifeRecord] {
        let cutoff = string(now.addingTimeInterval(-Self.retention))!
        return try database.transaction {
            let records = try database.query("""
                SELECT * FROM records WHERE deleted_at <= ?
                AND (media_path IS NOT NULL OR payload_json != '{}')
                """, [.text(cutoff)]).map(decode)
            for var record in records {
                record.payload = RecordPayload()
                record.media = nil
                record.updatedAt = now
                record.dirty = true
                try save(record)
            }
            return records
        }
    }

    public func pendingChanges(limit: Int = 100) throws -> [LifeRecord] {
        try database.query("SELECT * FROM records WHERE dirty=1 ORDER BY updated_at ASC LIMIT ?", [.integer(Int64(limit))]).map(decode)
    }

    public func markSynced(id: String, revision: Int64, matching updatedAt: Date? = nil) throws {
        if let updatedAt {
            try database.execute(
                "UPDATE records SET revision=?,dirty=CASE WHEN updated_at=? THEN 0 ELSE dirty END WHERE id=?",
                [.integer(revision), .text(string(updatedAt)!), .text(id)]
            )
        } else {
            try database.execute("UPDATE records SET dirty=0,revision=? WHERE id=? AND dirty=1", [.integer(revision), .text(id)])
        }
    }

    public func applyRemote(_ incoming: LifeRecord) throws {
        try database.transaction {
            if let local = try get(incoming.id, includeDeleted: true) {
                if incoming.revision <= local.revision { return }
                if local.deletedAt != nil, incoming.deletedAt == nil,
                   !local.allowsRestore(incoming) {
                    try preserveLocalChange(id: local.id, after: incoming.revision)
                    return
                }
                if local.dirty, local.deletedAt == nil, incoming.allowsRestore(local) {
                    try preserveLocalChange(id: local.id, after: incoming.revision)
                    return
                }
            }
            var value = incoming
            value.dirty = false
            try save(value)
        }
    }

    private func preserveLocalChange(id: String, after revision: Int64) throws {
        try database.execute("UPDATE records SET revision=?,dirty=1 WHERE id=?", [.integer(revision), .text(id)])
    }

    public func applyCloudDeletion(id: String) throws {
        guard var record = try get(id, includeDeleted: true) else { return }
        record.deletedAt = record.deletedAt ?? .now
        record.restoredFrom = nil
        record.updatedAt = .now
        record.dirty = false
        record.payload = RecordPayload()
        record.media = nil
        try save(record)
    }

    public func clearCloudRecords(now: Date = .now) throws -> [LifeRecord] {
        try database.transaction {
            let records = try list(includeDeleted: true, limit: Int.max)
            for var record in records {
                record.deletedAt = now.addingTimeInterval(-Self.retention)
                record.restoredFrom = nil
                record.updatedAt = now
                record.dirty = true
                record.payload = RecordPayload()
                record.media = nil
                try save(record)
            }
            return records
        }
    }

    public func syncValue(_ key: String) throws -> String? {
        try database.query("SELECT value FROM sync_state WHERE key=?", [.text(key)]).first?["value"]?.text
    }

    public func setSyncValue(_ value: String?, for key: String) throws {
        if let value {
            try database.execute("""
                INSERT INTO sync_state(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, [.text(key), .text(value)])
        } else {
            try database.execute("DELETE FROM sync_state WHERE key=?", [.text(key)])
        }
    }

    public func clearLocalData() throws {
        try database.transaction {
            try database.execute("DELETE FROM records")
            try database.execute("DELETE FROM sync_state")
        }
    }

    public func replaceAll(with records: [LifeRecord]) throws {
        try database.transaction {
            try database.execute("DELETE FROM records")
            for var record in records {
                record.dirty = true
                record.revision = 0
                try save(record)
            }
        }
    }

    public func logAccess(tool: String, count: Int) throws {
        try database.execute(
            "INSERT INTO agent_logs(tool_name,client_id,created_at,result_count) VALUES(?,?,?,?)",
            [.text(tool), .text("local"), .text(string(.now)!), .integer(Int64(count))]
        )
    }

    public func accessLogs(limit: Int = 100) throws -> [AccessLog] {
        try database.query("SELECT * FROM agent_logs ORDER BY id DESC LIMIT ?", [.integer(Int64(limit))]).compactMap { row in
            guard let id = row["id"]?.integer, let tool = row["tool_name"]?.text, let created = date(row["created_at"]?.text) else { return nil }
            return AccessLog(id: id, toolName: tool, createdAt: created, resultCount: Int(row["result_count"]?.integer ?? 0))
        }
    }
}
