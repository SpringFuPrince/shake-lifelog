import XCTest

final class LocalRecordingTests: XCTestCase {
    func testTimelinePinchShowsOnlyPhotosAndOpensDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["SHAKE_UI_TEST_PHOTO_GRID"] = "1"
        app.launch()
        let timeline = app.tabBars.buttons["时间线"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.tap()

        let list = app.descendants(matching: .any)["timeline.recordList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["timeline.density"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["测试文字记录"].exists)
        // Keep both simulated touches inside the timeline, above the floating tab bar.
        let row = app.descendants(matching: .any)["timeline.record.timeline-fixture-photo-2"].firstMatch
        XCTAssertTrue(row.exists)
        row.pinch(withScale: 0.55, velocity: -1.0)

        let grid = app.descendants(matching: .any)["timeline.photoGrid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["测试文字记录"].exists)
        let first = app.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-0"].firstMatch
        let second = app.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-1"].firstMatch
        XCTAssertTrue(first.exists && second.exists)
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1)
        let yesterday = app.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-6"].firstMatch
        let older = app.descendants(matching: .any)["timeline.photo.timeline-fixture-photo-7"].firstMatch
        XCTAssertTrue(yesterday.isHittable, "Yesterday's photo is visible after zooming")
        XCTAssertTrue(older.isHittable, "The previous day's photo is visible after zooming")
        let gridScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        gridScreenshot.name = "拾刻时间线照片网格"
        gridScreenshot.lifetime = .keepAlways
        add(gridScreenshot)
        older.tap()
        XCTAssertTrue(app.images["record.detail.photo"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["时间线"].tap()
        first.pinch(withScale: 2.1, velocity: 1.0)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.swipeDown()
        XCTAssertTrue(app.staticTexts["测试文字记录"].exists)
    }

    func testUnavailableCameraOffersManualRecording() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil else {
            throw XCTSkip("This test requires a simulator without a camera")
        }
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launch()

        let camera = app.tabBars.buttons["拍摄"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.tap()
        XCTAssertFalse(app.buttons["手动记"].exists)
        XCTAssertFalse(app.staticTexts["拍摄"].exists)
        let fallback = app.buttons["手动记录"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 10))
        fallback.tap()
        XCTAssertTrue(app.staticTexts["选择记录类别"].waitForExistence(timeout: 5))
        app.buttons["record.editor.category.sport"].tap()
        let activity = app.textFields["运动类型"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()
        activity.typeText("Camera fallback walk")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["Camera fallback walk"].waitForExistence(timeout: 5))
    }

    func testTimelineWithTenThousandRecords() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SIMULATOR_DEVICE_NAME"] != nil, environment["SHAKE_TIMELINE_FIXTURE"] == "1" else {
            throw XCTSkip("Enable the synthetic 10,000-record fixture on a simulator")
        }

        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launchEnvironment["SHAKE_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launch()
        let timeline = app.tabBars.buttons["时间线"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))

        let clock = ContinuousClock()
        let latest = app.staticTexts["Timeline fixture 10000"]
        var samples: [Double] = []
        for _ in 0..<5 {
            app.tabBars.buttons["首页"].tap()
            let start = clock.now
            timeline.tap()
            XCTAssertTrue(latest.waitForExistence(timeout: 5))
            let elapsed = start.duration(to: clock.now).components
            samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("Timeline first row (10,000 records, five simulator UI switches): \(samples.sorted()) ms")
        latest.tap()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["时间线"].tap()
        app.swipeUp()
        XCTAssertFalse(latest.isHittable)
    }

    func testLANSyncIsAvailableFromSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launch()

        let settings = app.tabBars.buttons["我的"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let sync = app.buttons["局域网同步"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()

        XCTAssertTrue(app.buttons["扫描 Mac 二维码"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["同步到 Mac"].exists)
    }

    func testSyntheticPhotoPersistsInRecordDetail() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
              ProcessInfo.processInfo.environment["SHAKE_PHOTO_FIXTURE"] == "1" else {
            throw XCTSkip("Run on a simulator with the synthetic photo fixture imported")
        }
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launch()

        let sport = app.buttons["运动"]
        XCTAssertTrue(sport.waitForExistence(timeout: 10))
        sport.tap()
        let addPhoto = app.buttons["添加照片"]
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5))
        addPhoto.tap()
        let asset = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()
        XCTAssertTrue(app.buttons["更换照片"].waitForExistence(timeout: 5))
        app.buttons["保存"].tap()

        app.terminate()
        app.launch()
        app.tabBars.buttons["时间线"].tap()
        let record = app.staticTexts["运动记录"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.images["record.detail.photo"].waitForExistence(timeout: 5))

        if ProcessInfo.processInfo.environment["SHAKE_EXPORT_FIXTURE"] == "1" {
            app.tabBars.buttons["我的"].tap()
            let export = app.buttons["导出备份"]
            XCTAssertTrue(export.waitForExistence(timeout: 5))
            export.tap()
            let save = app.buttons["DOCPicker.actionButton"]
            XCTAssertTrue(save.waitForExistence(timeout: 10))
            save.tap()
            XCTAssertTrue(save.waitForNonExistence(timeout: 10))
            XCTAssertTrue(export.isHittable)
        }
    }

    func testExerciseRelaunchCalendarEditingAndRecovery() {
        let app = XCUIApplication()
        app.launchEnvironment["SHAKE_UI_TEST_STORE"] = UUID().uuidString
        app.launch()

        let exercise = app.buttons["运动"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 10))
        exercise.tap()
        let type = app.textFields["运动类型"]
        XCTAssertTrue(type.waitForExistence(timeout: 5))
        type.tap()
        type.typeText("Evening walk")
        app.buttons["保存"].tap()

        app.terminate()
        app.launch()
        let latest = app.buttons["dashboard.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.label.contains("Evening walk"))
        let timeline = app.tabBars.buttons["时间线"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.tap()
        let entry = app.staticTexts["Evening walk"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record.filter.all"].label.contains("全部"))

        app.buttons["日历"].tap()
        let today = app.buttons["calendar.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        app.buttons["record.filter.food"].tap()
        XCTAssertTrue(today.label.contains("0 条记录"))
        today.tap()
        XCTAssertTrue(app.staticTexts["这天没有该类别的记录"].waitForExistence(timeout: 5))
        XCTAssertFalse(entry.exists)
        app.buttons["完成"].tap()
        app.buttons["record.filter.all"].tap()
        XCTAssertTrue(today.label.contains("1 条记录"))
        today.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.navigationBars.buttons["时间线"].tap()

        entry.tap()
        let activityDetail = app.descendants(matching: .any)["record.detail.activity"].firstMatch
        let durationDetail = app.descendants(matching: .any)["record.detail.duration"].firstMatch
        XCTAssertTrue(activityDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(durationDetail.exists)
        app.buttons["编辑"].tap()
        let duration = app.textFields["时长（分钟，选填）"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap()
        duration.typeText("25")
        app.buttons["保存"].tap()
        let edited = app.staticTexts["Evening walk · 25 分钟"]
        XCTAssertTrue(durationDetail.waitForExistence(timeout: 5))
        app.buttons["删除"].tap()
        app.buttons["删除记录"].tap()

        let deleted = app.navigationBars.buttons["最近删除"]
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        XCTAssertFalse(edited.exists)
        deleted.tap()
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        app.buttons["恢复"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
    }
}
