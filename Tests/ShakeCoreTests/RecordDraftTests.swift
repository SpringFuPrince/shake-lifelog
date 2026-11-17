import XCTest
@testable import ShakeCore

final class RecordDraftTests: XCTestCase {
    func testDefaultsDoNotCountAsManualContent() {
        var draft = RecordDraft(category: .weight, lastWeight: 62.5)
        XCTAssertFalse(draft.canSave)
        draft.payload.weightInherited = false
        XCTAssertTrue(draft.canSave)

        draft = RecordDraft(category: .food)
        XCTAssertFalse(draft.canSave)
        draft.confirmOptions()
        XCTAssertTrue(draft.canSave)
        draft.select(.mood)
        XCTAssertFalse(draft.canSave)
    }

    func testExerciseAllowsMissingDurationAndPreservesText() {
        XCTAssertEqual(Category.allCases.map(\.rawValue), ["food", "weight", "mood", "knowledge", "sport"])
        var draft = RecordDraft(category: .sport)
        XCTAssertFalse(draft.canSave)
        draft.payload.activity = "散步"
        XCTAssertNil(draft.payload.durationMinutes)
        XCTAssertTrue(draft.canSave)
        draft.payload.durationMinutes = 0
        XCTAssertFalse(draft.canSave)
        draft.select(.mood)
        XCTAssertEqual(draft.payload.activity, "散步")
        XCTAssertNil(draft.payload.durationMinutes)
    }

    func testPhotoOnlyWeightDoesNotInheritUnconfirmedValue() {
        let draft = RecordDraft(category: .weight, lastWeight: 62.5, hasPhoto: true)
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.payloadForSave.weight)
    }
}
