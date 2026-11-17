import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShakeCore
import ShakeUI
@testable import ShakeMacAgent

final class AgentIntegrationTests: XCTestCase {
    @MainActor
    func testLocalStreamableHTTPWithoutTokenAndLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "shake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cloud = try CloudSettings(settings: defaults, root: root)
        let repository = cloud.store.repository
        let server = MCPServer(port: 0, settings: defaults)
        defer {
            server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        var record = LifeRecord(category: .sport, payload: RecordPayload(activity: "步行"))
        record.media = try cloud.store.media.process(sampleJPEG(), recordID: record.id)
        record.payload.captureLocation = try XCTUnwrap(CaptureLocation(latitude: 31, longitude: 121))
        try repository.save(record)
        let meal = LifeRecord(category: .food, payload: RecordPayload(meal: .lunch, note: "测试午餐"))
        let confirmedWeight = LifeRecord(category: .weight, payload: RecordPayload(weight: 62.5))
        let knowledge = LifeRecord(category: .knowledge, payload: RecordPayload(title: "读书", content: "合成知识记录"))
        try repository.save(meal)
        try repository.save(confirmedWeight)
        try repository.save(LifeRecord(category: .weight, payload: RecordPayload(weight: 63.0, weightInherited: true)))
        try repository.save(knowledge)
        server.launchIfNeeded(cloud: cloud)
        XCTAssertEqual(server.status, .stopped)
        server.start()
        try await waitForStartup(server)
        XCTAssertEqual(server.status, .running)
        let port = try XCTUnwrap(server.boundPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        func call(_ method: String, params: [String: Any] = [:],
                  origin: String? = nil) async throws -> (status: Int, result: [String: Any]?) {
            try await self.call(url, method, params: params, origin: origin)
        }

        for clientName in ["codex", "claude"] {
            let option = "SHAKE_\(clientName.uppercased())_PROBE"
            guard ProcessInfo.processInfo.environment[option] == "1" else { continue }
            try await runClientProbe(clientName, root: root, url: url)
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["SHAKE_CLAUDE_LIVE"] == "1" {
            try await runClientProbe("live", root: root, url: url, arguments: ["claude", meal.id], timeout: 120)
        }

        let invalidOrigin = try await call("tools/list", origin: "https://example.invalid")
        XCTAssertEqual(invalidOrigin.status, 403)
        let discovery = try await call("tools/list")
        XCTAssertEqual(discovery.status, 200)
        let tools = try XCTUnwrap(discovery.result?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["list_categories", "search_records", "get_records"])

        let removedTool = try await call("tools/call", params: ["name": "get_daily_digest"])
        XCTAssertEqual(removedTool.result?["isError"] as? Bool, true)
        let read = try await call("tools/call", params: ["name": "get_records",
            "arguments": ["ids": [meal.id, record.id, "missing", record.id]]])
        let structured = try XCTUnwrap(read.result?["structuredContent"] as? [String: Any])
        let items = try XCTUnwrap(structured["records"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, [meal.id, record.id])
        XCTAssertEqual(structured["missing_ids"] as? [String], ["missing"])
        XCTAssertEqual((items[0]["photo"] as? [String: Any])?["status"] as? String, "none")
        let fields = try XCTUnwrap(items[1]["fields"] as? [String: Any])
        XCTAssertEqual(fields["activity"] as? String, "步行")
        XCTAssertNil(fields["captureLocation"])
        XCTAssertNil(items[1]["summary"])
        XCTAssertTrue(structured["data_as_of"] is NSNull)
        XCTAssertEqual(try repository.accessLogs().first?.resultCount, 2)

        func checkImage(_ item: [String: Any], in reply: [String: Any]?) throws {
            let photo = try XCTUnwrap(item["photo"] as? [String: Any])
            XCTAssertEqual(photo["status"] as? String, "available")
            let index = try XCTUnwrap(photo["content_index"] as? Int)
            let blocks = try XCTUnwrap(reply?["content"] as? [[String: String]])
            let jpeg = try XCTUnwrap(blocks.indices.contains(index) ? blocks[index] : nil)
            XCTAssertEqual(jpeg["type"], "image")
            XCTAssertEqual(jpeg["mimeType"], "image/jpeg")
            let bytes = try XCTUnwrap(jpeg["data"].flatMap { Data(base64Encoded: $0) })
            XCTAssertTrue(bytes.starts(with: [0xff, 0xd8, 0xff]))
        }
        try checkImage(items[1], in: read.result)

        let day = record.captureDay
        let search = try await call("tools/call", params: ["name": "search_records", "arguments": [
            "from": day, "to": day, "category": "sport", "keyword": "步行", "photo_size": "detail"
        ]])
        let searchData = try XCTUnwrap(search.result?["structuredContent"] as? [String: Any])
        let searchItems = try XCTUnwrap(searchData["records"] as? [[String: Any]])
        XCTAssertEqual(searchItems.first?["id"] as? String, record.id)
        try checkImage(try XCTUnwrap(searchItems.first), in: search.result)

        var another = LifeRecord(category: .sport, capturedAt: record.capturedAt,
                                 payload: RecordPayload(activity: "第二张照片"))
        another.media = try cloud.store.media.process(sampleJPEG(), recordID: another.id)
        try repository.save(another)
        let mixed = try await call("tools/call", params: ["name": "get_records",
            "arguments": ["ids": [record.id, meal.id, another.id]]])
        let mixedData = try XCTUnwrap(mixed.result?["structuredContent"] as? [String: Any])
        let mixedItems = try XCTUnwrap(mixedData["records"] as? [[String: Any]])
        XCTAssertEqual(mixedItems.compactMap { $0["id"] as? String }, [record.id, meal.id, another.id])
        XCTAssertEqual(mixedItems.map { ($0["photo"] as? [String: Any])?["content_index"] as? Int }, [1, nil, 2])
        try checkImage(mixedItems[0], in: mixed.result)
        try checkImage(mixedItems[2], in: mixed.result)

        let newestQuery: [String: Any] = ["limit": 1]
        let first = try await call("tools/call", params: ["name": "search_records", "arguments": newestQuery])
        func page(_ reply: [String: Any]?) throws -> [String: Any] {
            try XCTUnwrap(reply?["structuredContent"] as? [String: Any])
        }
        let firstPage = try page(first.result)
        let pageID = try XCTUnwrap((firstPage["records"] as? [[String: Any]])?.first?["id"] as? String)
        let cursor = try XCTUnwrap(firstPage["next_cursor"] as? String)
        try repository.softDelete(pageID)
        let second = try await call("tools/call", params: ["name": "search_records", "arguments": ["cursor": cursor, "limit": 2]])
        let secondPage = try page(second.result)
        let secondIDs = try XCTUnwrap((secondPage["records"] as? [[String: Any]])?.compactMap { $0["id"] as? String })
        XCTAssertEqual(secondIDs.count, 2)
        XCTAssertFalse(secondIDs.contains(pageID))
        let invalidCursor = try await call("tools/call", params: ["name": "search_records",
            "arguments": ["cursor": cursor, "order": "oldest"]])
        XCTAssertEqual(invalidCursor.result?["isError"] as? Bool, true)

        let midnight = try Date.ISO8601FormatStyle().parse("2024-01-01T00:20:00Z")
        var travel = LifeRecord(category: .sport, capturedAt: midnight, timezone: "America/Los_Angeles",
                                payload: RecordPayload(activity: "旅行步行"))
        travel.media = MediaRefs(original: "missing/original.jpg", thumbnail: "missing/thumb.jpg", preview: "missing/preview.jpg")
        try repository.save(travel)
        let travelReply = try await call("tools/call", params: [
            "name": "search_records", "arguments": ["to": "2023-12-31", "order": "oldest"]
        ])
        let travelRecords = try XCTUnwrap(try page(travelReply.result)["records"] as? [[String: Any]])
        XCTAssertEqual(travelRecords.compactMap { $0["id"] as? String }, [travel.id])
        XCTAssertEqual(travelRecords.first?["date"] as? String, "2023-12-31")
        XCTAssertEqual((travelRecords.first?["photo"] as? [String: Any])?["status"] as? String, "unavailable")

        server.stop()
        XCTAssertEqual(server.status, .stopped)
        let relaunched = MCPServer(port: port, settings: defaults)
        relaunched.launchIfNeeded(cloud: cloud)
        XCTAssertEqual(relaunched.status, .stopped)
        do {
            _ = try await call("tools/list")
            XCTFail("监听停止后仍能连接")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    @MainActor
    func testSearchLatencyWithTenThousandRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "shake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cloud = try CloudSettings(settings: defaults, root: root)
        let repository = cloud.store.repository
        let server = MCPServer(port: 0)
        defer {
            server.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date.now
        try repository.database.transaction {
            for index in 0..<10_000 {
                let date = now.addingTimeInterval(-Double(index) * 120)
                let payload = RecordPayload(meal: .lunch, note: "合成饮食记录")
                try repository.save(LifeRecord(category: .food, capturedAt: date, payload: payload))
            }
        }
        server.launchIfNeeded(cloud: cloud)
        server.start()
        try await waitForStartup(server)
        let port = try XCTUnwrap(server.boundPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let dayFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        let from = now.addingTimeInterval(-15 * 86_400).formatted(dayFormat)
        let arguments: [String: Any] = ["from": from, "to": now.formatted(dayFormat), "category": "food",
                                        "keyword": "饮食", "limit": 12]
        let params: [String: Any] = ["name": "search_records", "arguments": arguments]
        var timings: [Double] = []
        for _ in 0..<20 {
            let started = ProcessInfo.processInfo.systemUptime
            let response = try await call(url, "tools/call", params: params)
            timings.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            let content = try XCTUnwrap(response.result?["structuredContent"] as? [String: Any])
            XCTAssertEqual((content["records"] as? [[String: Any]])?.count, 12)
        }
        let p95 = timings.sorted()[18]
        print("MCP search_records: 10,000 records, 20 requests, P95 = \(p95.formatted()) ms")
        XCTAssertLessThanOrEqual(p95, 500)
    }

    @MainActor
    func testOccupiedPortCanRecoverAfterListenerStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "shake-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cloud = try CloudSettings(settings: defaults, root: root)
        let first = MCPServer(port: 0)
        defer {
            first.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        first.launchIfNeeded(cloud: cloud)
        first.start()
        try await waitForStartup(first)
        XCTAssertEqual(first.status, .running)
        let port = try XCTUnwrap(first.boundPort)
        let second = MCPServer(port: port)
        defer { second.stop() }
        second.launchIfNeeded(cloud: cloud)
        second.start()
        try await waitForStartup(second)
        guard case .failed(let message) = second.status else { return XCTFail("占用端口应提示启动失败") }
        XCTAssertTrue(message.contains(String(port)))

        first.stop()
        // Network.framework releases the socket asynchronously after cancellation.
        for _ in 0..<10 where second.status != .running {
            try await Task.sleep(for: .milliseconds(100))
            second.start()
            try await waitForStartup(second)
        }
        XCTAssertEqual(second.status, .running)
        XCTAssertEqual(second.boundPort, port)
    }

    @MainActor
    private func waitForStartup(_ server: MCPServer) async throws {
        for _ in 0..<40 where server.status == .starting {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func sampleJPEG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func call(_ url: URL, _ method: String, params: [String: Any] = [:],
                      origin: String? = nil) async throws -> (status: Int, result: [String: Any]?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, object?["result"] as? [String: Any])
    }
}

func runClientProbe(_ name: String, root: URL, url: URL, arguments: [String] = [],
                    timeout: TimeInterval = 45) async throws {
    let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ClientAcceptance/\(name)_probe.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [probe.path, root.path, url.absoluteString] + arguments
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let deadline = Date.now.addingTimeInterval(timeout)
    while process.isRunning, Date.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    guard !process.isRunning else { XCTFail("\(name) probe timed out"); return }
    XCTAssertEqual(process.terminationStatus, 0, "\(name) probe")
}
