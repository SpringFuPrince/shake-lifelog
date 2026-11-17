import CryptoKit
import XCTest
@testable import ShakeCore

final class LANSyncTests: XCTestCase {
    func testPairingAndAuthenticatedReceipt() throws {
        let pairing = try LANPairing(host: "192.168.1.12", port: 17877, name: "测试 Mac")
        let decoded = try LANPairing(code: pairing.code)
        XCTAssertEqual(decoded, pairing)
        XCTAssertThrowsError(try LANPairing(code: pairing.code.replacingOccurrences(of: "/v2?", with: "/v1?"))) {
            XCTAssertEqual($0 as? LANSyncError, .incompatibleVersion)
        }
        XCTAssertThrowsError(try LANPairing(host: "8.8.8.8", port: 17877, name: "远端"))
        XCTAssertThrowsError(try LANPairing(code: "https://example.com/"))

        let record = LifeRecord(category: .sport, payload: RecordPayload(activity: "验收散步"))
        let item = LANRecord(record: record, photo: nil)
        let request = try LANWire.sealRequest(item, pairing: pairing)
        XCTAssertNil(String(data: request, encoding: .utf8)?.range(of: "验收散步"))
        XCTAssertEqual(try LANWire.openRequest(request, pairing: decoded).record.id, record.id)

        let other = try LANPairing(host: pairing.host, port: pairing.port, name: pairing.name)
        XCTAssertThrowsError(try LANWire.openRequest(request, pairing: other))
        let response = try LANWire.sealReceipt(.imported, request: request, pairing: pairing)
        XCTAssertEqual(try LANWire.openReceipt(response, request: request, pairing: pairing), .imported)
        let anotherRequest = try LANWire.sealRequest(item, pairing: pairing)
        XCTAssertThrowsError(try LANWire.openReceipt(response, request: anotherRequest, pairing: pairing))
    }

    func testInventoryContainsOnlyBoundedIDsAndBindsReplyToItsRequest() throws {
        let pairing = try LANPairing(host: "192.168.1.12", port: 17877, name: "测试 Mac")
        let ids = (0..<LANWire.maxInventoryIDs).map { _ in UUID().uuidString }
        let request = try LANWire.sealInventory(ids, pairing: pairing)
        XCTAssertLessThan(request.count, LANWire.maxInventoryBytes)
        XCTAssertEqual(try LANWire.openInventory(request, pairing: pairing), ids)
        XCTAssertThrowsError(try LANWire.openRequest(request, pairing: pairing))
        XCTAssertThrowsError(try LANWire.sealInventory(ids + [UUID().uuidString], pairing: pairing))

        let missing = [ids[1], ids[5]]
        let response = try LANWire.sealMissingIDs(missing, request: request, pairing: pairing)
        XCTAssertEqual(try LANWire.openMissingIDs(response, request: request, offered: ids, pairing: pairing), Set(missing))
        let retry = try LANWire.sealInventory(ids, pairing: pairing)
        XCTAssertThrowsError(try LANWire.openMissingIDs(response, request: retry, offered: ids, pairing: pairing))
        let unrelated = try LANWire.sealMissingIDs([UUID().uuidString], request: request, pairing: pairing)
        XCTAssertThrowsError(try LANWire.openMissingIDs(unrelated, request: request, offered: ids, pairing: pairing))
    }

    func testImportKeepsOriginalIDAndDoesNotOverwriteExistingOrDeletedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordRepository(path: root.appendingPathComponent("db.sqlite").path)
        let media = try MediaStore(root: root.appendingPathComponent("media"))
        let importer = LANImporter(repository: repository, media: media)
        var record = LifeRecord(category: .sport, payload: RecordPayload(activity: "验收散步"))
        XCTAssertEqual(try importer.importRecord(LANRecord(record: record, photo: nil)), .imported)
        record.payload.activity = "更改"
        XCTAssertEqual(try importer.importRecord(LANRecord(record: record, photo: nil)), .skipped)
        XCTAssertEqual(try repository.list().map(\.id), [record.id])
        XCTAssertEqual(try repository.get(record.id)?.payload.activity, "验收散步")
        try repository.softDelete(record.id)
        XCTAssertEqual(try importer.importRecord(LANRecord(record: record, photo: nil)), .skipped)
        XCTAssertTrue(try repository.list().isEmpty)
    }

    func testUnreadablePhotoDoesNotLeaveRecordOrFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try RecordRepository(path: root.appendingPathComponent("db.sqlite").path)
        let media = try MediaStore(root: root.appendingPathComponent("media"))
        let importer = LANImporter(repository: repository, media: media)
        var record = LifeRecord(category: .sport, payload: RecordPayload(activity: "验收散步"))
        record.media = MediaRefs(original: "source/original.jpg", thumbnail: "source/thumbnail.jpg", preview: "source/preview.jpg")
        XCTAssertThrowsError(try importer.importRecord(LANRecord(record: record, photo: Data("invalid JPEG".utf8))))
        XCTAssertNil(try repository.get(record.id, includeDeleted: true))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: media.root.path).isEmpty)
    }
}
