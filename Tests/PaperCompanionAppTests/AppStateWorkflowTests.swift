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
    func testMarginNoteAnchorsToSelectionAndIsMarkedQuiet() {
        let state = AppState()
        state.currentPageIndex = 4
        state.currentPageLabel = "5"
        state.currentSelection = selection()
        state.commentDraft = "nice explanation"

        state.addQuickNote()

        XCTAssertEqual(state.comments.count, 1)
        XCTAssertEqual(state.comments[0].kind, .quiet)
        XCTAssertEqual(state.comments[0].highlightID, state.activeHighlights.first?.id)
        XCTAssertEqual(state.comments[0].pageLabel, "5")
        XCTAssertTrue(state.commentDraft.isEmpty)
    }

    @MainActor
    func testMarginNoteFallsBackToPageWhenNothingIsSelected() {
        let state = AppState()
        state.currentPageIndex = 1
        state.currentPageLabel = "2"
        state.commentDraft = "this table is unreadable"

        state.addQuickNote()

        XCTAssertEqual(state.comments.count, 1)
        XCTAssertEqual(state.comments[0].kind, .quiet)
        XCTAssertNil(state.comments[0].highlightID)
        XCTAssertEqual(state.comments[0].pageLabel, "2")
        XCTAssertTrue(state.activeHighlights.isEmpty)
    }

    @MainActor
    func testOrdinaryCommentsRemainDiscussKind() {
        let state = AppState()
        state.currentPageLabel = "5"
        state.commentDraft = "The estimand is unclear."

        state.addComment(linkToHighlight: false)

        XCTAssertEqual(state.comments[0].kind, .discuss)
    }

    @MainActor
    func testSelectingHighlightTargetsItForNavigation() {
        let state = AppState()
        state.currentSelection = selection()
        state.addHighlight()
        let highlight = state.activeHighlights[0]
        state.navigationHighlightID = nil

        state.selectHighlight(highlight)

        XCTAssertEqual(state.navigationHighlightID, highlight.id)
        XCTAssertEqual(state.navigationPageIndex, highlight.pageIndex)
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

extension AppStateWorkflowTests {
    @MainActor
    private func stateWithHighlight() -> (AppState, HighlightRecord) {
        let state = AppState()
        state.currentPageIndex = 4
        state.currentPageLabel = "5"
        state.currentSelection = SelectionSnapshot(
            selectedText: "A theoretically important passage",
            prefix: "Before. ",
            suffix: " After.",
            locations: [
                HighlightLocation(
                    pageIndex: 4, pageLabel: "5",
                    lineRects: [RectRecord(x: 10, y: 20, width: 100, height: 12)],
                    textRanges: [TextRangeRecord(location: 30, length: 33)]
                )
            ]
        )
        state.addHighlight()
        state.selectionChanged(nil)
        return (state, state.activeHighlights[0])
    }

    @MainActor
    func testHighlightClickSelectsEntryAndRevealsItWithoutNavigating() {
        let (state, highlight) = stateWithHighlight()
        state.inspectorTab = .agent
        let navigationBefore = state.navigationRequestID
        let revealBefore = state.sidebarRevealRequestID

        state.highlightClicked(highlight.id)

        XCTAssertEqual(state.selectedHighlightID, highlight.id)
        XCTAssertEqual(state.selectedEntryID, highlight.id)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertEqual(state.sidebarRevealID, highlight.id)
        XCTAssertNotEqual(state.sidebarRevealRequestID, revealBefore)
        XCTAssertEqual(state.navigationRequestID, navigationBefore, "clicking in the PDF must not scroll the PDF")
    }

    @MainActor
    func testSelectingAnExpandedEntryCollapsesIt() {
        let (state, _) = stateWithHighlight()
        let entry = state.annotationEntries[0]

        state.selectEntry(entry)
        XCTAssertEqual(state.selectedEntryID, entry.id)
        state.selectEntry(entry)
        XCTAssertNil(state.selectedEntryID)
    }

    @MainActor
    func testPageOnlyCommentBecomesTheSelectedEntry() {
        let state = AppState()
        state.currentPageIndex = 2
        state.currentPageLabel = "3"
        state.commentDraft = "Page-level thought"

        state.saveCommentFromKeyboard()

        XCTAssertNil(state.comments[0].highlightID, "no anchor means ⌘↩ saves to the page")
        XCTAssertEqual(state.selectedCommentID, state.comments[0].id)
        XCTAssertEqual(state.annotationEntries.map(\.id), [state.comments[0].id])
    }

    @MainActor
    func testKeyboardSaveLinksWhenAHighlightIsActive() {
        let (state, highlight) = stateWithHighlight()
        state.selectHighlight(highlight)
        state.commentDraft = "Linked by keyboard"

        state.saveCommentFromKeyboard()

        XCTAssertEqual(state.comments[0].highlightID, highlight.id)
        XCTAssertEqual(state.selectedHighlightID, highlight.id, "the entry stays expanded after saving")
    }

    @MainActor
    func testEditingACommentKeepsItsIDAndCanBeUndone() {
        let state = AppState()
        state.currentPageIndex = 0
        state.currentPageLabel = "1"
        state.commentDraft = "Frist draft"
        state.addComment(linkToHighlight: false)
        let id = state.comments[0].id

        state.updateComment(id, verbatim: "First draft")
        XCTAssertEqual(state.comments[0].id, id)
        XCTAssertEqual(state.comments[0].verbatim, "First draft")

        state.performUndo()
        XCTAssertEqual(state.comments[0].verbatim, "Frist draft")
        state.performRedo()
        XCTAssertEqual(state.comments[0].verbatim, "First draft")
    }
}

extension AppStateWorkflowTests {
    @MainActor
    func testDeleteKeyRemovesTheSelectedHighlightAndIsUndoable() {
        let (state, highlight) = stateWithHighlight()
        XCTAssertFalse(state.deleteSelectedEntry(), "nothing selected: the key falls through")

        // Creation and deletion happen in separate events in the app; without a
        // run-loop turn NSUndoManager would fold both into one undo group.
        RunLoop.main.run(until: Date())
        state.highlightClicked(highlight.id)
        XCTAssertTrue(state.deleteSelectedEntry())

        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertNil(state.selectedEntryID)
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.map(\.id), [highlight.id])
    }

    @MainActor
    func testDeleteKeyRemovesASelectedPageOnlyComment() {
        let state = AppState()
        state.currentPageIndex = 0
        state.currentPageLabel = "1"
        state.commentDraft = "page-level"
        state.addComment(linkToHighlight: false)
        XCTAssertNotNil(state.selectedCommentID)

        XCTAssertTrue(state.deleteSelectedEntry())

        XCTAssertTrue(state.activeComments.isEmpty)
        XCTAssertNil(state.selectedEntryID)
    }
}

extension AppStateWorkflowTests {
    @MainActor
    func testHighlightDeletionRemovesLinkedCommentsAndUndoRestoresExactStatuses() {
        let (state, highlight) = stateWithHighlight()
        let linked = CommentRecord(highlightID: highlight.id, verbatim: "Linked", status: "answered")
        let alreadyDeleted = CommentRecord(highlightID: highlight.id, verbatim: "Old", status: "deleted")
        let standalone = CommentRecord(verbatim: "Page note")
        state.comments = [linked, alreadyDeleted, standalone]
        state.undoManager.removeAllActions()
        state.highlightClicked(highlight.id)
        XCTAssertTrue(state.deleteSelectedEntry())
        XCTAssertEqual(state.activeComments.map(\.id), [standalone.id])
        state.performUndo()
        XCTAssertEqual(state.comments, [linked, alreadyDeleted, standalone])
        XCTAssertEqual(state.activeHighlights.count, 1)
        state.performRedo()
        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertEqual(state.activeComments.map(\.id), [standalone.id])
    }

    @MainActor
    func testHighlightColorCanBeChangedAndUndone() {
        let (state, highlight) = stateWithHighlight()
        state.undoManager.removeAllActions()
        state.setHighlightColor(highlight.id, color: "green")
        XCTAssertEqual(state.activeHighlights.first?.color, "green")
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.first?.color, "yellow")
        state.performRedo()
        XCTAssertEqual(state.activeHighlights.first?.color, "green")
        state.setHighlightColor(highlight.id, color: "invalid")
        XCTAssertEqual(state.activeHighlights.first?.color, "green")
    }
}
