import Foundation
import ShakeCore
import ShakeUI
import XCTest
@testable import ShakeMacAgent
@testable import ShakeMacLAN

final class LANReceiverTests: XCTestCase {
    @MainActor
    func testIncrementalSyncReadsOnlyMissingPhotosAcrossBatches() async throws {
        let address: String
        do { address = try LANReceiver.localAddress() }
        catch { throw XCTSkip("The host needs a private IPv4 address") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mac = try ShakeStore(root: root.appendingPathComponent("Mac"))
        let phoneMedia = try MediaStore(root: root.appendingPathComponent("iPhone photos"))
        let receiver = LANReceiver(port: 0)
        defer {
            receiver.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let existing = (0..<LANWire.maxInventoryIDs).map { index in
            LifeRecord(category: .sport, payload: RecordPayload(activity: "已导入 \(index)"))
        }
        try mac.repository.database.transaction {
            for record in existing { try mac.repository.save(record) }
        }
        try mac.repository.softDelete(existing[0].id)
        var phoneRecords = existing
        // Keeping references without installing the files proves a duplicate photo is never opened.
        phoneRecords[0].media = MediaRefs(original: "old/original.jpg", thumbnail: "old/thumb.jpg", preview: "old/preview.jpg")
        phoneRecords[1].media = phoneRecords[0].media

        var new = LifeRecord(category: .sport, payload: RecordPayload(activity: "新照片"))
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let photo = try Data(contentsOf: fixtures.appendingPathComponent("ShakeIOSUITests/Fixtures/checkerboard.png"))
        new.media = try phoneMedia.process(photo, recordID: new.id)
        phoneRecords.append(new)

        receiver.start(importer: LANImporter(repository: mac.repository, media: mac.media), address: address) {}
        for _ in 0..<80 where receiver.isStarting { try await Task.sleep(for: .milliseconds(25)) }
        let pairing = try XCTUnwrap(receiver.pairing)
        var progress = LANSyncProgress()
        try await LANConnection.synchronize(phoneRecords, media: phoneMedia, pairing: pairing) { progress = $0 }
        XCTAssertEqual(progress.skipped, existing.count)
        XCTAssertEqual(progress.imported, 1)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertNil(try mac.repository.get(existing[0].id))
        XCTAssertEqual(try mac.repository.get(new.id)?.payload.activity, "新照片")
        let refs = try XCTUnwrap(try mac.repository.get(new.id)?.media)
        XCTAssertTrue(mac.media.isAvailable(refs))

        try phoneMedia.clear()
        try await LANConnection.synchronize(phoneRecords, media: phoneMedia, pairing: pairing) { progress = $0 }
        XCTAssertEqual(progress.skipped, phoneRecords.count)
        XCTAssertEqual(progress.imported, 0)
        XCTAssertEqual(progress.failed, 0)
        XCTAssertEqual(receiver.importedCount, 1)
    }

    @MainActor
    func testLANImportIsVisibleToLoopbackMCP() async throws {
        let address: String
        do { address = try LANReceiver.localAddress() }
        catch { throw XCTSkip("The host needs a private IPv4 address") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "shake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let phone = try ShakeStore(root: root.appendingPathComponent("iPhone"))
        let cloud = try CloudSettings(settings: defaults, root: root.appendingPathComponent("Mac"))
        let receiver = LANReceiver(port: 0)
        let mcp = MCPServer(port: 0)
        defer {
            receiver.stop()
            mcp.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let record = LifeRecord(category: .sport, payload: RecordPayload(activity: "LAN QA walk"))
        var withPhoto = record
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let photo = try Data(contentsOf: fixtures.appendingPathComponent("ShakeIOSUITests/Fixtures/checkerboard.png"))
        withPhoto.media = try phone.media.process(photo, recordID: record.id)
        try phone.repository.save(withPhoto)
        let item = try LANRecord.prepare(withPhoto, media: phone.media)
        receiver.start(importer: LANImporter(repository: cloud.store.repository, media: cloud.store.media), address: address) {
            try? cloud.store.refresh()
        }
        for _ in 0..<80 where receiver.isStarting { try await Task.sleep(for: .milliseconds(25)) }
        let pairing = try LANPairing(code: XCTUnwrap(receiver.pairing).code)
        let first = try await LANConnection.request(item, pairing: pairing)
        let second = try await LANConnection.request(item, pairing: pairing)
        XCTAssertEqual(first, .imported)
        XCTAssertEqual(second, .skipped)
        XCTAssertEqual(cloud.store.records.map(\.id), [record.id])
        let refs = try XCTUnwrap(cloud.store.records.first?.media)
        XCTAssertTrue(cloud.store.media.isAvailable(refs))

        var meal = LifeRecord(category: .food, payload: RecordPayload(meal: .lunch, note: "测试午餐"))
        meal.media = try phone.media.process(photo, recordID: meal.id)
        let weight = LifeRecord(category: .weight, payload: RecordPayload(weight: 62.5))
        let referenceWeight = LifeRecord(category: .weight, payload: RecordPayload(weight: 63, weightInherited: true))
        let knowledge = LifeRecord(category: .knowledge, payload: RecordPayload(title: "读书", content: "合成知识记录"))
        let reviewRecords = [meal, weight, referenceWeight, knowledge]
        for reviewRecord in reviewRecords {
            try phone.repository.save(reviewRecord)
            let saved = try XCTUnwrap(phone.repository.get(reviewRecord.id))
            let receipt = try await LANConnection.request(LANRecord.prepare(saved, media: phone.media), pairing: pairing)
            XCTAssertEqual(receipt, .imported)
        }
        XCTAssertEqual(Set(cloud.store.records.map(\.id)), Set(([record] + reviewRecords).map(\.id)))
        var packagedMealID: String?
        if ProcessInfo.processInfo.environment["SHAKE_CODEX_VISION"] == "1" {
            let label = try Data(contentsOf: fixtures.appendingPathComponent("ClientAcceptance/Fixtures/nutrition-label.png"))
            var packagedMeal = LifeRecord(category: .food, payload: RecordPayload(meal: .snack, note: "整包吃完"))
            packagedMeal.media = try phone.media.process(label, recordID: packagedMeal.id)
            try phone.repository.save(packagedMeal)
            let packagedItem = try LANRecord.prepare(packagedMeal, media: phone.media)
            let packagedReceipt = try await LANConnection.request(packagedItem, pairing: pairing)
            XCTAssertEqual(packagedReceipt, .imported)
            packagedMealID = packagedMeal.id
        }

        mcp.launchIfNeeded(cloud: cloud)
        mcp.start()
        for _ in 0..<80 where mcp.status == .starting { try await Task.sleep(for: .milliseconds(25)) }
        let port = try XCTUnwrap(mcp.boundPort)
        receiver.stop()
        XCTAssertNil(receiver.pairing)
        XCTAssertEqual(mcp.status, .running)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        var query = URLRequest(url: url)
        query.httpMethod = "POST"
        query.setValue("application/json", forHTTPHeaderField: "Content-Type")
        query.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "get_records", "arguments": ["ids": [record.id]]]
        ])
        let (body, response) = try await URLSession.shared.data(for: query)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let imported = try XCTUnwrap((structured["records"] as? [[String: Any]])?.first)
        XCTAssertEqual(imported["id"] as? String, record.id)
        XCTAssertEqual((imported["fields"] as? [String: Any])?["activity"] as? String, "LAN QA walk")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue(content.contains { $0["mimeType"] as? String == "image/jpeg" })
        if ProcessInfo.processInfo.environment["SHAKE_CODEX_PROBE"] == "1" {
            try await runClientProbe("codex", root: root, url: url,
                                     arguments: [record.id, meal.id, weight.id, knowledge.id])
        }
        if ProcessInfo.processInfo.environment["SHAKE_CODEX_LIVE"] == "1" {
            try await runClientProbe("live", root: root, url: url,
                                     arguments: ["codex", meal.id, weight.id, knowledge.id], timeout: 120)
        }
        if let packagedMealID {
            try await runClientProbe("live", root: root, url: url,
                                     arguments: ["codex-vision", meal.id, packagedMealID], timeout: 120)
        }
    }
}
