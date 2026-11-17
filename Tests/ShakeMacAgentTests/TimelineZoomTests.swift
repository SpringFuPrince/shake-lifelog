import XCTest
@testable import ShakeUI

final class TimelineZoomTests: XCTestCase {
    func testPhotoCrossingARowResizesAndMovesDuringZoom() {
        let two = TimelinePhotoLayout(columns: 2).tileFrame(at: 2, width: 320)
        let middle = TimelinePhotoLayout(columns: 2.5).tileFrame(at: 2, width: 320)
        let three = TimelinePhotoLayout(columns: 3).tileFrame(at: 2, width: 320)

        XCTAssertGreaterThan(two.minY, middle.minY)
        XCTAssertGreaterThan(middle.minY, three.minY)
        XCTAssertLessThan(two.minX, middle.minX)
        XCTAssertLessThan(middle.minX, three.minX)
        XCTAssertGreaterThan(two.width, middle.width)
        XCTAssertGreaterThan(middle.width, three.width)
        XCTAssertEqual(three.maxX, 320, accuracy: 0.01)
    }

    func testLayoutIsContinuousAcrossColumnBoundary() {
        let before = TimelinePhotoLayout(columns: 2.999).tileFrame(at: 7, width: 560)
        let after = TimelinePhotoLayout(columns: 3.001).tileFrame(at: 7, width: 560)
        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
        XCTAssertEqual(before.minX, after.minX, accuracy: 1)
        XCTAssertEqual(before.width, after.width, accuracy: 1)
    }
}
