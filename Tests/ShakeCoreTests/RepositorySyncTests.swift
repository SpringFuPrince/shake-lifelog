import XCTest
@testable import ShakeCore

final class RepositorySyncTests: XCTestCase {
    func testPhotoLocationSurvivesCategoryChangesStorageAndTransfer() throws {
        try withRepository { repository in
            let location = try XCTUnwrap(CaptureLocation(latitude: 31.23, longitude: 121.47, horizontalAccuracy: 20))
            var draft = RecordDraft(category: .food, hasPhoto: true, source: .camera)
            draft.payload.captureLocation = location
            draft.select(.knowledge)
            let record = LifeRecord(category: draft.category, payload: draft.payloadForSave, source: draft.source)
            try repository.save(record)

            let stored = try XCTUnwrap(repository.get(record.id))
            XCTAssertEqual(stored.payload.captureLocation, location)
            let transferred = try ShakeCoding.decoder.decode(LifeRecord.self, from: ShakeCoding.encoder.encode(stored))
            XCTAssertEqual(transferred.payload.captureLocation, location)
            XCTAssertNil(try JSONDecoder().decode(RecordPayload.self, from: Data("{}".utf8)).captureLocation)
        }
    }

    func testAcknowledgingAnOlderSnapshotKeepsNewLocalEditPending() throws {
        try withRepository { repository in
            let first = LifeRecord(category: .food, payload: RecordPayload(note: "first"))
            try repository.save(first)
            var second = first
            second.payload.note = "second"
            second.updatedAt = first.updatedAt.addingTimeInterval(1)
            try repository.save(second)
            try repository.markSynced(id: first.id, revision: 1, matching: first.updatedAt)
            let current = try XCTUnwrap(repository.get(first.id))
            XCTAssertTrue(current.dirty)
            XCTAssertEqual(current.revision, 1)
            XCTAssertEqual(current.payload.note, "second")
        }
    }

    func testExpiredDeletionRetainsTombstoneAndRejectsStaleRecord() throws {
        try withRepository { repository in
            let now = Date.now
            let first = LifeRecord(category: .food, payload: RecordPayload(note: "before removal"), revision: 2)
            try repository.save(first)
            try repository.softDelete(first.id, now: now.addingTimeInterval(-31 * 86_400))
            try repository.restore(first.id, now: now)
            XCTAssertNil(try repository.get(first.id))
            XCTAssertEqual(try repository.purgeExpired(now: now).map(\.id), [first.id])
            var remote = first
            remote.revision = 1
            try repository.applyRemote(remote)
            let tombstone = try XCTUnwrap(repository.get(first.id, includeDeleted: true))
            XCTAssertNotNil(tombstone.deletedAt)
            XCTAssertEqual(tombstone.payload, RecordPayload())
            XCTAssertNil(tombstone.media)
            XCTAssertTrue(tombstone.dirty)
        }
    }

    func testNewerRevisionCannotResurrectDeletionWithoutExplicitRestore() throws {
        try withRepository { repository in
            let record = LifeRecord(category: .food, payload: RecordPayload(note: "first"), revision: 1)
            try repository.save(record)
            let now = Date.now
            try repository.softDelete(record.id, now: now)
            try repository.markSynced(id: record.id, revision: 2)

            var stale = record
            stale.revision = 3
            try repository.applyRemote(stale)
            XCTAssertNil(try repository.get(record.id))
            XCTAssertEqual(try repository.pendingChanges().first?.revision, 3)

            let deletion = try XCTUnwrap(repository.get(record.id, includeDeleted: true)?.deletedAt)
            var restored = record
            restored.revision = 4
            restored.restoredFrom = deletion
            restored.updatedAt = now.addingTimeInterval(1)
            try repository.applyRemote(restored)
            XCTAssertEqual(try repository.get(record.id)?.revision, 4)
        }
    }

    func testPurgedDeletionRejectsLateRestoreEvenAtNewerRevision() throws {
        try withRepository { repository in
            let now = Date.now
            let record = LifeRecord(category: .knowledge, payload: RecordPayload(title: "private"), revision: 1)
            try repository.save(record)
            try repository.softDelete(record.id, now: now.addingTimeInterval(-31 * 86_400))
            let deletion = try XCTUnwrap(repository.get(record.id, includeDeleted: true)?.deletedAt)
            _ = try repository.purgeExpired(now: now)
            try repository.markSynced(id: record.id, revision: 2)

            var late = record
            late.revision = 3
            late.restoredFrom = deletion
            late.updatedAt = now
            try repository.applyRemote(late)
            XCTAssertNil(try repository.get(record.id))
            let tombstone = try XCTUnwrap(repository.get(record.id, includeDeleted: true))
            XCTAssertEqual(tombstone.payload, RecordPayload())
            XCTAssertTrue(tombstone.dirty)
            XCTAssertEqual(tombstone.revision, 3)
        }
    }

    func testRestoreBeforeFirstUploadSurvivesReceiptOfItsDeletion() throws {
        try withRepository { repository in
            let record = LifeRecord(category: .mood, payload: RecordPayload(note: "first"), revision: 1)
            try repository.save(record)
            let now = Date.now
            try repository.softDelete(record.id, now: now)
            var cloud = try XCTUnwrap(repository.get(record.id, includeDeleted: true))
            cloud.revision = 2
            try repository.restore(record.id, now: now.addingTimeInterval(1))
            try repository.applyRemote(cloud)
            XCTAssertEqual(try repository.get(record.id)?.revision, 2)
            XCTAssertEqual(try repository.pendingChanges().first?.id, record.id)
        }
    }

    func testPendingRecordsSurviveReopeningDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let filename = path.appendingPathComponent("shake.sqlite").path
        let record = LifeRecord(category: .sport, payload: RecordPayload(activity: "步行"), source: .camera)
        try RecordRepository(path: filename).save(record)
        let reopened = try RecordRepository(path: filename)
        XCTAssertEqual(try reopened.pendingChanges().first?.source, .camera)
        XCTAssertEqual(try reopened.pendingChanges().first?.payload.activity, "步行")
    }

    private func withRepository(_ operation: (RecordRepository) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(RecordRepository(path: root.appendingPathComponent("test.sqlite").path))
    }
}
