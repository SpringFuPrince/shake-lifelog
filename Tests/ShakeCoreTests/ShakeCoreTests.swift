import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShakeCore

final class ShakeCoreTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents(); components.year = 2026; components.month = 11; components.day = 10; components.hour = hour; components.minute = minute
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: components)!
    }
    func testMealDefaults() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(Meal.at(date(5), timeZone: zone), .breakfast)
        XCTAssertEqual(Meal.at(date(10, 30), timeZone: zone), .lunch)
        XCTAssertEqual(Meal.at(date(14, 30), timeZone: zone), .snack)
        XCTAssertEqual(Meal.at(date(17), timeZone: zone), .dinner)
        XCTAssertEqual(Meal.at(date(23), timeZone: zone), .snack)
    }
    func testCaptureDayUsesTheSavedTimeZone() throws {
        let instant = try Date.ISO8601FormatStyle().parse("2026-11-15T00:20:00Z")
        var record = LifeRecord(category: .sport, capturedAt: instant, timezone: "America/Los_Angeles", payload: .init())
        XCTAssertEqual(record.captureDay, "2026-11-14")
        record.timezone = "Asia/Shanghai"
        XCTAssertEqual(record.captureDay, "2026-11-15")
        record.timezone = "Unknown"
        XCTAssertEqual(record.captureDay, "2026-11-15")
    }
    func testPhotoAndManualValidation() {
        var photo = RecordDraft(category: .food, hasPhoto: true)
        photo.payload.note = nil
        XCTAssertTrue(photo.canSave)
        let empty = RecordDraft(category: .food, hasPhoto: false)
        XCTAssertFalse(empty.canSave)
        var manual = empty; manual.payload.note = "  一顿便饭  "; XCTAssertTrue(manual.canSave)
        var weight = RecordDraft(category: .weight, hasPhoto: false); XCTAssertFalse(weight.canSave)
        weight.payload.weight = 68.4; XCTAssertTrue(weight.canSave)
    }
    func testCategorySwitchPreservesTextAndResetsOptions() {
        var draft = RecordDraft(category: .food, lastWeight: 68.4)
        draft.payload.note = "保留我"
        draft.select(.weight, lastWeight: 68.4)
        XCTAssertEqual(draft.payload.note, "保留我")
        XCTAssertNil(draft.payload.meal)
        XCTAssertEqual(draft.payload.weight, 68.4)
        XCTAssertEqual(draft.payload.weightInherited, true)
    }
    func testLowConfidencePolicy() {
        let result = ClassificationPolicy.draft(from: [Classification(category: .mood, confidence: 0.42), Classification(category: .daily, confidence: 0.3)], at: .now, lastWeight: nil)
        XCTAssertEqual(result.draft.category, .mood)
        XCTAssertEqual(result.alternatives.count, 2)
    }

    private func makeStore() throws -> (RecordRepository, MediaStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try RecordRepository(path: root.appendingPathComponent("test.sqlite").path), try MediaStore(root: root.appendingPathComponent("media")), root)
    }
    func testRepositoryCRUDFiltersAndTombstones() throws {
        let (repository, _, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, category) in Category.allCases.enumerated() {
            try repository.save(LifeRecord(id: "record-\(index)", category: category, capturedAt: date(index + 6), payload: .defaults(for: category)))
        }
        XCTAssertEqual(try repository.list().count, 5)
        XCTAssertEqual(try repository.list(category: .food).count, 1)
        try repository.softDelete("record-0")
        XCTAssertEqual(try repository.list().count, 4)
        XCTAssertEqual(try repository.list(deletedOnly: true).count, 1)
        try repository.restore("record-0")
        XCTAssertEqual(try repository.list().count, 5)
        let pending = try repository.pendingChanges()
        XCTAssertEqual(pending.count, 5)
        try repository.markSynced(id: "record-0", revision: 9)
        XCTAssertEqual(try repository.get("record-0")?.revision, 9)
        XCTAssertFalse(try repository.get("record-0")!.dirty)
    }
    func testRemoteDeletionWins() throws {
        let (repository, _, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let original = LifeRecord(id: "same", category: .daily, payload: RecordPayload(note: "old"), updatedAt: date(8), dirty: false)
        try repository.save(original)
        var remote = original; remote.updatedAt = date(9); remote.deletedAt = date(9); remote.revision = 2; remote.payload.note = "new"
        try repository.applyRemote(remote)
        XCTAssertNotNil(try repository.get("same", includeDeleted: true)?.deletedAt)

    }
    func testBackupMergeAndReplace() throws {
        let (repository, media, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let image = Self.testJPEG()
        let refs = try media.process(image, recordID: id)
        try repository.save(LifeRecord(id: id, category: .food, payload: .defaults(for: .food), media: refs))
        let backup = root.appendingPathComponent("backup.shake")
        try BackupManager(repository: repository, media: media).export(to: backup)
        try repository.softDelete(id)
        try BackupManager(repository: repository, media: media).restore(from: backup, mode: .merge)
        XCTAssertNotNil(try repository.get(id, includeDeleted: true)?.deletedAt, "合并按 ID 去重，不覆盖已有记录")
        try BackupManager(repository: repository, media: media).restore(from: backup, mode: .replace)
        XCTAssertNil(try repository.get(id)?.deletedAt)
        XCTAssertEqual(try repository.list().count, 1)
    }
    func testFailedExportPreservesExistingBackup() throws {
        let (repository, media, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("existing.zip")
        let manager = BackupManager(repository: repository, media: media)
        try repository.save(LifeRecord(category: .mood, payload: RecordPayload(note: "old")))
        try manager.export(to: backup)
        let previous = try Data(contentsOf: backup)

        let id = UUID().uuidString
        let refs = try media.process(Self.testJPEG(), recordID: id)
        let damagedFile = media.url(for: refs.preview)
        try FileManager.default.removeItem(at: damagedFile)
        try FileManager.default.createDirectory(at: damagedFile, withIntermediateDirectories: false)
        try repository.save(LifeRecord(id: id, category: .food, payload: .defaults(for: .food), media: refs))

        XCTAssertThrowsError(try manager.export(to: backup))
        XCTAssertEqual(try Data(contentsOf: backup), previous)
    }

    func testMissingThumbnailKeepsCloudPhotoEligibleForDownload() throws {
        let (_, media, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = try media.process(Self.testJPEG(), recordID: UUID().uuidString)
        XCTAssertTrue(media.isAvailable(refs))
        try FileManager.default.removeItem(at: media.url(for: refs.thumbnail))
        XCTAssertFalse(media.isAvailable(refs))
        try media.installCloudPhoto(media.data(refs.original), refs: refs)
        XCTAssertTrue(media.isAvailable(refs))
    }

    func testPhotoCanReadCaptureLocationAndReencodedMediaDropsGPS() throws {
        let (_, media, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let input = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(input, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 30.0, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 110.0, kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let location = try XCTUnwrap(MediaStore.captureLocation(from: input as Data))
        XCTAssertEqual(location.latitude, -30)
        XCTAssertEqual(location.longitude, -110)
        let refs = try media.process(input as Data, recordID: UUID().uuidString)
        let output = try XCTUnwrap(CGImageSourceCreateWithData(try media.data(refs.original) as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 20)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 40)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    private static func testJPEG() -> Data {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let data = NSMutableData(); let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return data as Data
    }
}
