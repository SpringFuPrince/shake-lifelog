import Foundation

public struct LANImporter {
    private let repository: RecordRepository
    private let media: MediaStore

    public init(repository: RecordRepository, media: MediaStore) {
        self.repository = repository
        self.media = media
    }

    public func missingRecordIDs(_ ids: [String]) throws -> [String] {
        let existing = try repository.existingRecordIDs(ids)
        // Deleted rows also count as existing so retrying an import does not restore them.
        return ids.filter { !existing.contains($0) }
    }

    public func importRecord(_ item: LANRecord) throws -> LANReceipt {
        var record = item.record
        guard UUID(uuidString: record.id) != nil, record.deletedAt == nil,
              (record.media != nil) == (item.photo != nil),
              (item.photo?.count ?? 0) <= LANWire.maxPhotoBytes else { throw LANSyncError.invalidTransfer }
        // Media lives in its own directory so rollback never removes an existing record's files.
        let mediaDirectory = "lan-" + UUID().uuidString.lowercased()
        do {
            return try repository.database.transaction {
                if try repository.get(record.id, includeDeleted: true) != nil { return .skipped }
                if let photo = item.photo {
                    record.media = try media.process(photo, recordID: mediaDirectory)
                }
                record.revision = 0
                record.restoredFrom = nil
                record.dirty = true
                try repository.save(record)
                return .imported
            }
        } catch {
            if item.photo != nil { try? FileManager.default.removeItem(at: media.url(for: mediaDirectory)) }
            throw error
        }
    }
}
