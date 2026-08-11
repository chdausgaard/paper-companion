import Foundation
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

final class AppStateWorkflowTests: XCTestCase {
    private func selection() -> SelectionSnapshot {
        SelectionSnapshot(
            selectedText: "A theoretically important passage",
            prefix: "Before. ",
            suffix: " After.",
            locations: [
                HighlightLocation(
                    pageIndex: 4,
                    pageLabel: "5",
                    lineRects: [RectRecord(x: 10, y: 20, width: 100, height: 12)],
                    textRanges: [TextRangeRecord(location: 30, length: 33)]
                )
            ]
        )
    }

    @MainActor
    func testLinkedCommentCreatesHighlightFromCurrentSelection() {
        let state = AppState()
        state.currentPageIndex = 4
        state.currentPageLabel = "5"
        state.currentSelection = selection()
        state.commentDraft = "This claim needs stronger evidence."

        state.addComment(linkToHighlight: true)

        XCTAssertEqual(state.activeHighlights.count, 1)
        XCTAssertEqual(state.comments.count, 1)
        XCTAssertEqual(state.comments[0].highlightID, state.activeHighlights[0].id)
        XCTAssertEqual(state.comments[0].pageLabel, "5")
        XCTAssertTrue(state.commentDraft.isEmpty)
    }

    @MainActor
    func testPageOnlyCommentIgnoresCurrentSelectionWithoutLosingComment() {
        let state = AppState()
        state.currentPageIndex = 4
        state.currentPageLabel = "5"
        state.currentSelection = selection()
        state.commentDraft = "A page-level observation."

        state.addComment(linkToHighlight: false)

        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertEqual(state.comments.count, 1)
        XCTAssertNil(state.comments[0].highlightID)
        XCTAssertEqual(state.comments[0].pageLabel, "5")
        XCTAssertEqual(state.comments[0].verbatim, "A page-level observation.")
    }

    @MainActor
    func testHighlightCreationCanBeUndoneAndRedone() {
        let state = AppState()
        let undoManager = UndoManager()
        state.undoManager = undoManager
        state.currentSelection = selection()

        state.addHighlight()
        XCTAssertEqual(state.activeHighlights.count, 1)
        XCTAssertTrue(undoManager.canUndo)

        state.performUndo()
        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertTrue(undoManager.canRedo)

        state.performRedo()
        XCTAssertEqual(state.activeHighlights.count, 1)
    }

    @MainActor
    func testCommentDeletionIsHiddenAndCanBeUndone() {
        let state = AppState()
        state.currentPageIndex = 1
        state.currentPageLabel = "2"
        state.commentDraft = "A removable page comment."
        state.addComment(linkToHighlight: false)
        let commentID = state.activeComments[0].id

        state.deleteComment(commentID)
        XCTAssertTrue(state.activeComments.isEmpty)

        state.performUndo()
        XCTAssertEqual(state.activeComments.map(\.id), [commentID])
    }

    @MainActor
    func testDuplicateHighlightRequestDoesNotCreateDuplicateRecord() {
        let state = AppState()
        state.currentSelection = selection()

        state.addHighlight()
        state.addHighlight()

        XCTAssertEqual(state.activeHighlights.count, 1)
    }
}
