import Foundation
import Network
import XCTest

final class AgentLifecycleTests: XCTestCase {
    private let port: UInt16 = 17964

    func testCommandWheelTimelineZoomOnLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["SHAKE_UI_TEST_MCP_PORT"] = String(port)
        app.launchEnvironment["SHAKE_UI_TEST_PHOTO_GRID"] = "1"
        app.launch()
        app.activate()
        let window = app.windows.firstMatch

        let list = window.descendants(matching: .any)["timeline.recordList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        XCTAssertFalse(window.descendants(matching: .any)["timeline.density"].firstMatch.exists)
        XCUIElement.perform(withKeyModifiers: .command) { list.scroll(byDeltaX: 0, deltaY: -8) }
        let grid = window.descendants(matching: .any)["timeline.photoGrid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["测试文字记录"].exists)
        let first = window.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-0"].firstMatch
        let second = window.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-1"].firstMatch
        XCTAssertTrue(first.exists && second.exists)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "拾刻 Mac 照片时间线"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIElement.perform(withKeyModifiers: .command) { grid.scroll(byDeltaX: 0, deltaY: 8) }
        XCTAssertTrue(app.descendants(matching: .any)["timeline.recordList"].firstMatch.waitForExistence(timeout: 5))

        let settings = app.descendants(matching: .any)["workspace.page.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.sync.icloud"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.sync.lan"].firstMatch.exists)
    }

    func testClosingMainWindowKeepsAgentAvailableUntilQuit() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["SHAKE_UI_TEST_MCP_PORT"] = String(port)
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertThrowsError(try statusCode())
        let agent = window.staticTexts["Agent"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        agent.click()
        let start = window.buttons["启动服务"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(window.staticTexts["运行中"].waitForExistence(timeout: 5))
        let status = try statusCode()
        XCTAssertEqual(status, 200)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        let afterClose = try statusCode()
        XCTAssertEqual(afterClose, 200)

        app.terminate()
        XCTAssertThrowsError(try statusCode())
    }

    private func statusCode() throws -> Int {
        let expectation = expectation(description: "loopback response")
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: .tcp)
        let queue = DispatchQueue(label: "shake.lifecycle.test")
        let result = Response()
        client.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
                let request = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(self.port)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
                client.send(content: request, completion: .contentProcessed { _ in })
                client.receive(minimumIncompleteLength: 16, maximumLength: 1024) { data, _, _, _ in
                    result.status = data.flatMap { String(decoding: $0, as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) } }
                    expectation.fulfill()
                }
            case .failed:
                expectation.fulfill()
            default:
                break
            }
        }
        client.start(queue: queue)
        defer { client.cancel() }
        guard XCTWaiter.wait(for: [expectation], timeout: 3) == .completed, let status = result.status else {
            throw URLError(.cannotConnectToHost)
        }
        return status
    }

    private final class Response: @unchecked Sendable {
        var status: Int?
    }
}
