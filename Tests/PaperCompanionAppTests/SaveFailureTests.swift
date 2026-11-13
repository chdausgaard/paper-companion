import Foundation
import PDFKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// A save that fails must not leave memory, the files and the journal saying
/// different things. If the records or the journal event could not be
/// written, the action did not happen: memory is put back, the records are
/// written again to match, no event exists for it and there is nothing to
/// undo. If both were written and only a later step failed (the context
/// file), the action happened: it is kept with its undo, and the error says
/// so. Failures are forced as in `RegionWorkflowTests`: a folder where a file
/// belongs. Each runs in a real session in a temporary folder.
final class SaveFailureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        restoreStandardDefaultsAfterTest()
        // The real pointer on this Mac must not decide the result.
        pinPointerStateForTest()
    }

    private var sessions: [RegionTestSession] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for session in sessions { session.remove() }
            sessions = []
        }
        super.tearDown()
    }

    @MainActor
    private func session() throws -> RegionTestSession {
        let session = try RegionTestSession()
        sessions.append(session)
        session.state.undoManager = UndoManager()
        return session
    }

    private func selection(_ text: String = "A theoretically important passage") -> SelectionSnapshot {
        SelectionSnapshot(
            selectedText: text,
            prefix: "Before. ",
            suffix: " After.",
            locations: [
                HighlightLocation(
                    pageIndex: 0,
                    pageLabel: "1",
                    lineRects: [RectRecord(x: 10, y: 20, width: 100, height: 12)],
                    textRanges: [TextRangeRecord(location: 30, length: text.count)]
                )
            ]
        )
    }

    // MARK: Breaking and reading the files

    /// A non-empty folder where the file belongs, so writing it fails.
    private func breakFile(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: url.appendingPathComponent("blocker"))
    }

    private func repairFile(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    @MainActor
    private func highlightsOnDisk(_ session: RegionTestSession) throws -> [HighlightRecord] {
        try JSONDecoder.paperCompanion.decode([HighlightRecord].self, from: Data(contentsOf: session.paths.highlights))
    }

    @MainActor
    private func commentsOnDisk(_ session: RegionTestSession) throws -> [CommentRecord] {
        try JSONDecoder.paperCompanion.decode([CommentRecord].self, from: Data(contentsOf: session.paths.comments))
    }

    /// Journal events as (kind, recordID).
    @MainActor
    private func journal(_ session: RegionTestSession) throws -> [(kind: String, recordID: UUID?)] {
        let text = try String(contentsOf: session.paths.eventLog, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return (object["kind"] as? String ?? "", (object["recordID"] as? String).flatMap(UUID.init(uuidString:)))
        }
    }

    @MainActor
    private func journalKinds(_ session: RegionTestSession) throws -> [String] {
        try journal(session).map(\.kind)
    }

    /// Lets the run loop close the current undo group and run the tasks the
    /// app queued, as between two user actions.
    @MainActor
    private func nextEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor
    private func savedHighlight(_ session: RegionTestSession) throws -> HighlightRecord {
        let state = session.state
        state.currentSelection = selection()
        state.addHighlight()
        nextEvent()
        return try XCTUnwrap(state.activeHighlights.first)
    }

    @MainActor
    private func savedComment(_ session: RegionTestSession, text: String = "Is this identified?", linkedTo highlight: HighlightRecord? = nil) throws -> CommentRecord {
        let state = session.state
        if let highlight { state.selectHighlight(highlight, navigate: false) }
        state.commentDraft = text
        state.addComment(linkToHighlight: highlight != nil)
        nextEvent()
        return try XCTUnwrap(state.comments.last)
    }

    // MARK: createHighlight

    /// The records were written, then the journal failed: the highlight is
    /// taken out of memory and out of the records, so the agent never sees
    /// it, and there is nothing to undo.
    @MainActor
    func testHighlightWhoseJournalFailsIsNowhere() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.eventLog)

        state.currentSelection = selection()
        state.addHighlight()

        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertNil(state.selectedHighlightID)
        XCTAssertTrue(try highlightsOnDisk(session).isEmpty, "the records were written back without it")
        XCTAssertFalse(state.undoManager.canUndo)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the highlight:"), message)
        XCTAssertFalse(message.contains("could not be put back"), "the second write worked")
        XCTAssertNil(state.commentFocusRequestID, "no cursor in the comment box for a highlight that does not exist")
    }

    /// A state file fails part way (comments.json after highlights.json):
    /// the write back fails at the same place, and that is reported.
    @MainActor
    func testHighlightWhoseStateSaveFailsReportsASecondFailure() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.comments)

        state.currentSelection = selection()
        state.addHighlight()

        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertTrue(try highlightsOnDisk(session).isEmpty, "highlights.json was put back before comments.json failed again")
        XCTAssertEqual(try journalKinds(session), ["session_created"], "no event")
        XCTAssertFalse(state.undoManager.canUndo)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the highlight:"), message)
        XCTAssertTrue(message.contains("The session files could not be put back to match either"), message)
    }

    /// Saved and journalled, then the context file failed: the highlight
    /// exists, with its undo, and the error says it was saved.
    @MainActor
    func testHighlightWhoseContextWriteFailsIsKept() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.currentContextJSON)

        state.currentSelection = selection()
        state.addHighlight()

        let highlight = try XCTUnwrap(state.activeHighlights.first)
        XCTAssertEqual(state.selectedHighlightID, highlight.id)
        XCTAssertEqual(try highlightsOnDisk(session).map(\.id), [highlight.id])
        XCTAssertEqual(try journal(session).last?.kind, "highlight_created")
        XCTAssertEqual(try journal(session).last?.recordID, highlight.id)
        XCTAssertEqual(state.undoManager.undoActionName, "Highlight")
        XCTAssertEqual(state.statusMessage, "Highlight saved · page 1")
        XCTAssertNotNil(state.commentFocusRequestID, "the comment box still gets the cursor")
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("The highlight was saved, but the agent’s current context could not be updated"), message)

        try repairFile(session.paths.currentContextJSON)
        nextEvent()
        state.performUndo()
        XCTAssertTrue(state.activeHighlights.isEmpty, "⌘Z removes it")
        XCTAssertEqual(try journal(session).last?.kind, "highlight_deleted")
    }

    // MARK: addComment

    /// The agent watches comments.json and the journal: a comment that
    /// reached comments.json and then failed must leave it again. The draft
    /// is kept so nothing the user typed is lost.
    @MainActor
    func testCommentWhoseJournalFailsLeavesTheFilesTheAgentWatches() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.eventLog)

        state.commentDraft = "Is this identified?"
        state.addComment(linkToHighlight: false)

        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertTrue(try commentsOnDisk(session).isEmpty, "comments.json was written back without it")
        XCTAssertFalse(try String(contentsOf: session.paths.commentsMarkdown, encoding: .utf8).contains("Is this identified?"))
        XCTAssertEqual(state.commentDraft, "Is this identified?", "the draft is kept")
        XCTAssertNil(state.selectedCommentID)
        XCTAssertFalse(state.undoManager.canUndo)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the comment:"), message)
        XCTAssertFalse(message.contains("could not be put back"))
    }

    /// comments.json itself cannot be written: nothing reached it, memory
    /// is back, and the failed write back is reported.
    @MainActor
    func testCommentWhoseStateSaveFailsReportsASecondFailure() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.comments)

        state.commentDraft = "Is this identified?"
        state.addComment(linkToHighlight: false)

        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertEqual(try journalKinds(session), ["session_created"])
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.contains("The session files could not be put back to match either"), message)
    }

    // MARK: updateComment

    @MainActor
    func testEditWhoseJournalFailsKeepsTheSavedText() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        try breakFile(session.paths.eventLog)

        state.updateComment(comment.id, verbatim: "Is this really identified?")

        XCTAssertEqual(state.comments.first?.verbatim, "Is this identified?")
        XCTAssertEqual(state.comments.first?.updatedAt, comment.updatedAt)
        XCTAssertEqual(try commentsOnDisk(session).first?.verbatim, "Is this identified?", "comments.json was written back")
        XCTAssertFalse(state.undoManager.canUndo, "no edit to undo")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not update the comment:"))
    }

    /// ⌘Z on an edit, and the save of the old text fails: the comment keeps
    /// the text that is saved, and ⌘Z still offers the undo, which works once
    /// the session can be written again.
    @MainActor
    func testUndoOfAnEditThatCannotBeSavedIsOfferedAgain() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        state.updateComment(comment.id, verbatim: "Is this really identified?")
        nextEvent()
        try breakFile(session.paths.eventLog)

        state.performUndo()
        nextEvent()

        XCTAssertEqual(state.comments.first?.verbatim, "Is this really identified?", "memory matches what is saved")
        XCTAssertEqual(try commentsOnDisk(session).first?.verbatim, "Is this really identified?")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not update the comment:"))
        XCTAssertEqual(state.undoManager.undoActionName, "Edit Comment", "the undo is still there")

        try repairFile(session.paths.eventLog)
        state.errorMessage = nil
        state.performUndo()
        XCTAssertEqual(state.comments.first?.verbatim, "Is this identified?")
        XCTAssertEqual(try commentsOnDisk(session).first?.verbatim, "Is this identified?")
        XCTAssertNil(state.errorMessage)
    }

    // MARK: Comment delete and restore

    @MainActor
    func testCommentDeletionThatCannotBeSavedLeavesTheCommentInPlace() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        XCTAssertEqual(state.selectedCommentID, comment.id)
        let eventsBefore = try journalKinds(session)
        try breakFile(session.paths.comments)

        XCTAssertTrue(state.deleteSelectedEntry())

        XCTAssertEqual(state.activeComments.map(\.id), [comment.id])
        XCTAssertEqual(state.comments.first?.updatedAt, comment.updatedAt)
        XCTAssertEqual(state.selectedCommentID, comment.id, "still there, still selected")
        XCTAssertEqual(try journalKinds(session), eventsBefore, "no event says it was deleted")
        XCTAssertFalse(state.undoManager.canUndo)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not update the comment:"), message)
        XCTAssertTrue(message.contains("could not be put back"), message)
    }

    @MainActor
    func testCommentDeletionWhoseJournalFailsIsWrittenBack() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        try breakFile(session.paths.eventLog)

        state.deleteComment(comment.id)

        XCTAssertEqual(state.activeComments.map(\.id), [comment.id])
        XCTAssertEqual(try commentsOnDisk(session).first?.status, comment.status, "comments.json says it is not deleted")
        XCTAssertFalse(state.undoManager.canUndo)
    }

    /// Restoring a deleted comment (⌘Z) fails: it stays deleted where it is
    /// deleted on disk, and ⌘Z still offers to restore it.
    @MainActor
    func testCommentRestoreThatCannotBeSavedIsOfferedAgain() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        state.deleteComment(comment.id)
        nextEvent()
        try breakFile(session.paths.eventLog)

        state.performUndo()
        nextEvent()

        XCTAssertTrue(state.activeComments.isEmpty)
        XCTAssertEqual(try commentsOnDisk(session).first?.status, "deleted")
        XCTAssertEqual(state.undoManager.undoActionName, "Delete Comment")

        try repairFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.activeComments.map(\.id), [comment.id])
        XCTAssertEqual(try commentsOnDisk(session).first?.status, comment.status)
        XCTAssertEqual(try journal(session).last?.kind, "comment_restored")
    }

    // MARK: Highlight delete and restore

    @MainActor
    func testHighlightDeletionWhoseJournalFailsKeepsItAndItsComments() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        let comment = try savedComment(session, linkedTo: highlight)
        let undoBefore = state.undoManager.undoActionName
        try breakFile(session.paths.eventLog)

        state.highlightClicked(highlight.id)
        XCTAssertTrue(state.deleteSelectedEntry())

        XCTAssertEqual(state.activeHighlights.map(\.id), [highlight.id])
        XCTAssertEqual(state.activeComments.map(\.id), [comment.id])
        XCTAssertEqual(state.selectedHighlightID, highlight.id, "still selected")
        XCTAssertNil(try highlightsOnDisk(session).first?.deletedAt, "highlights.json written back")
        XCTAssertEqual(try commentsOnDisk(session).first?.status, comment.status, "comments.json written back")
        XCTAssertEqual(state.undoManager.undoActionName, undoBefore, "no Remove Highlight to undo")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not update the highlight:"))
    }

    /// Saved and journalled, then the context file failed: removed, with
    /// its undo, and the error says it was removed.
    @MainActor
    func testHighlightDeletionWhoseContextWriteFailsIsKept() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        try breakFile(session.paths.currentContextJSON)

        state.deleteHighlight(highlight.id)

        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertNotNil(try highlightsOnDisk(session).first?.deletedAt)
        XCTAssertEqual(try journal(session).last?.kind, "highlight_deleted")
        XCTAssertEqual(state.undoManager.undoActionName, "Remove Highlight")
        XCTAssertEqual(state.statusMessage, "Highlight and linked comments removed · ⌘Z to undo")
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("The highlight was removed, but the agent’s current context could not be updated"), message)
    }

    /// Restoring a removed highlight (⌘Z) fails: it stays removed, with its
    /// comments, everywhere, and ⌘Z still offers to restore it.
    @MainActor
    func testHighlightRestoreThatCannotBeSavedIsOfferedAgain() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        let comment = try savedComment(session, linkedTo: highlight)
        state.deleteHighlight(highlight.id)
        nextEvent()
        try breakFile(session.paths.eventLog)

        state.performUndo()
        nextEvent()

        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertTrue(state.activeComments.isEmpty)
        XCTAssertNotNil(try highlightsOnDisk(session).first?.deletedAt)
        XCTAssertEqual(try commentsOnDisk(session).first?.status, "deleted")
        XCTAssertEqual(state.undoManager.undoActionName, "Remove Highlight")

        try repairFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.map(\.id), [highlight.id])
        XCTAssertEqual(state.activeComments.map(\.id), [comment.id])
        XCTAssertNil(try highlightsOnDisk(session).first?.deletedAt)
        XCTAssertEqual(try journal(session).last?.kind, "highlight_restored")
    }

    // MARK: setHighlightColor

    @MainActor
    func testColorChangeThatCannotBeSavedReportsASecondFailure() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        let undoBefore = state.undoManager.undoActionName
        try breakFile(session.paths.comments)

        state.setHighlightColor(highlight.id, color: "green")

        XCTAssertEqual(state.highlights.first?.color, "yellow")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "yellow", "highlights.json written back before comments.json failed again")
        XCTAssertEqual(state.undoManager.undoActionName, undoBefore)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the highlight color:"), message)
        XCTAssertTrue(message.contains("could not be put back"), message)
    }

    @MainActor
    func testUndoOfAColorChangeThatCannotBeSavedIsOfferedAgain() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        state.setHighlightColor(highlight.id, color: "green")
        nextEvent()
        try breakFile(session.paths.eventLog)

        state.performUndo()
        nextEvent()

        XCTAssertEqual(state.highlights.first?.color, "green")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "green")
        XCTAssertEqual(state.undoManager.undoActionName, "Change Highlight Color")

        try repairFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.highlights.first?.color, "yellow")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "yellow")
    }

    // MARK: Nothing the user typed is lost

    /// The sidebar list and composer in an offscreen window.
    @MainActor
    private func sidebar(_ state: AppState) -> (NSView, NSWindow) {
        let host = NSHostingView(rootView: AnnotationsView().environmentObject(state).frame(width: 420, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        let window = offscreenWindow(for: host)
        spin()
        return (host, window)
    }

    @MainActor
    private func textView(showing text: String, under host: NSView) -> NSTextView? {
        descendants(of: host, as: NSTextView.self).first { $0.string == text && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// A card edit whose save fails stays open with the new wording, through
    /// the card's real Edit and Save buttons; once the session can be
    /// written, the same Save saves it and closes the editor.
    @MainActor
    func testACardEditThatCannotBeSavedStaysOpenWithTheDraft() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        XCTAssertEqual(state.selectedCommentID, comment.id, "the card is expanded")
        let (host, window) = sidebar(state)
        defer { closeOffscreenWindow(window) }

        let labels = { self.accessibilityNodes(under: host).map(\.label).filter { !$0.isEmpty } }
        let edit = try XCTUnwrap(accessibilityNode(labeled: "Edit", under: host) ?? accessibilityNode(labeled: "pencil", under: host),
                                 "edit button among \(labels())")
        realClick(atWindowPoint: edit.center, in: window)
        let editor = try XCTUnwrap(textView(showing: "Is this identified?", under: host), "the editor opened")
        editor.selectAll(nil)
        editor.insertText("Is this really identified?", replacementRange: editor.selectedRange())
        spin(0.1)
        try breakFile(session.paths.eventLog)

        let save = try XCTUnwrap(accessibilityNode(labeled: "Save", under: host), "Save among \(labels())")
        realClick(atWindowPoint: save.center, in: window)

        XCTAssertNotNil(state.errorMessage, "the failure is reported")
        XCTAssertEqual(state.comments.first?.verbatim, "Is this identified?", "nothing was saved")
        XCTAssertNotNil(textView(showing: "Is this really identified?", under: host), "the editor is still open with the new wording")
        XCTAssertNotNil(accessibilityNode(labeled: "Save", under: host), "and its Save button")

        try repairFile(session.paths.eventLog)
        state.errorMessage = nil
        let saveAgain = try XCTUnwrap(accessibilityNode(labeled: "Save", under: host))
        realClick(atWindowPoint: saveAgain.center, in: window)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.comments.first?.verbatim, "Is this really identified?")
        XCTAssertEqual(try commentsOnDisk(session).first?.verbatim, "Is this really identified?")
        XCTAssertNil(accessibilityNode(labeled: "Save", under: host), "saved: the editor closed")
    }

    /// The composer's draft survives a failed save through its real Save
    /// button, in the box itself, and the next Save sends it.
    @MainActor
    func testTheComposerKeepsADraftThatCannotBeSaved() throws {
        let session = try session()
        let state = session.state
        let (host, window) = sidebar(state)
        defer { closeOffscreenWindow(window) }
        state.commentDraft = "Is this identified?"
        spin(0.1)
        XCTAssertNotNil(textView(showing: "Is this identified?", under: host), "the draft is in the box")
        try breakFile(session.paths.eventLog)

        let save = try XCTUnwrap(accessibilityNode(labeled: "Save to page", under: host))
        realClick(atWindowPoint: save.center, in: window)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.comments.isEmpty)
        XCTAssertEqual(state.commentDraft, "Is this identified?")
        XCTAssertNotNil(textView(showing: "Is this identified?", under: host), "still in the box")

        try repairFile(session.paths.eventLog)
        state.errorMessage = nil
        realClick(atWindowPoint: save.center, in: window)
        XCTAssertEqual(state.comments.map(\.verbatim), ["Is this identified?"])
        XCTAssertEqual(state.commentDraft, "")
    }

    /// Notes are never rolled back: a save that fails, explicit or automatic,
    /// leaves the text in the box and says so.
    @MainActor
    func testNotesThatCannotBeSavedStayInTheBox() throws {
        let session = try session()
        let state = session.state
        try breakFile(session.paths.eventLog)
        state.notes = "My notes"
        state.saveNotes()
        XCTAssertEqual(state.notes, "My notes")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not save notes:"))

        state.errorMessage = nil
        try breakFile(session.paths.notes)
        state.notes = "My notes, longer"
        state.scheduleNotesSave()
        spin(1.0)
        XCTAssertEqual(state.notes, "My notes, longer")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not autosave notes:"))
    }

    // MARK: A failed undo or redo leaves both stacks as they were

    /// Yellow, then green, then blue, each its own undo step.
    @MainActor
    private func threeColors(_ session: RegionTestSession) throws -> HighlightRecord {
        let state = session.state
        let highlight = try savedHighlight(session)
        state.setHighlightColor(highlight.id, color: "green")
        nextEvent()
        state.setHighlightColor(highlight.id, color: "blue")
        nextEvent()
        return highlight
    }

    /// Codex's case: undo the second change (works), then the first undo
    /// cannot be saved. The redo of the second change must survive, and the
    /// failed undo must still be there.
    @MainActor
    func testAFailedUndoKeepsBothStacks() throws {
        let session = try session()
        let state = session.state
        let highlight = try threeColors(session)
        state.performUndo()
        nextEvent()
        XCTAssertEqual(state.highlights.first?.color, "green")
        try breakFile(session.paths.eventLog)

        state.performUndo()

        XCTAssertEqual(state.highlights.first?.color, "green", "nothing changed")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "green")
        XCTAssertEqual(state.undoManager.undoActionName, "Change Highlight Color")
        XCTAssertTrue(state.undoManager.canRedo, "the redo is still there")
        XCTAssertEqual(state.undoManager.redoActionName, "Change Highlight Color")

        try repairFile(session.paths.eventLog)
        nextEvent()
        state.performRedo()
        XCTAssertEqual(state.highlights.first?.color, "blue", "the redo is the one it was")
        XCTAssertFalse(state.undoManager.canRedo)
        state.performUndo()
        state.performUndo()
        XCTAssertEqual(state.highlights.first?.color, "yellow", "and the failed undo works now")
        state.performUndo()
        XCTAssertTrue(state.activeHighlights.isEmpty, "then the creation")
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertEqual(state.highlights.first?.id, highlight.id)
    }

    /// The mirror: a redo that cannot be saved leaves the undo stack and the
    /// redo stack as they were.
    @MainActor
    func testAFailedRedoKeepsBothStacks() throws {
        let session = try session()
        let state = session.state
        _ = try threeColors(session)
        state.performUndo()
        state.performUndo()
        nextEvent()
        XCTAssertEqual(state.highlights.first?.color, "yellow")
        try breakFile(session.paths.eventLog)

        state.performRedo()

        XCTAssertEqual(state.highlights.first?.color, "yellow", "nothing changed")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "yellow")
        XCTAssertEqual(state.undoManager.undoActionName, "Highlight", "the undo stack is as it was")
        XCTAssertEqual(state.undoManager.redoActionName, "Change Highlight Color")

        try repairFile(session.paths.eventLog)
        nextEvent()
        state.performRedo()
        XCTAssertEqual(state.highlights.first?.color, "green", "the failed redo works now")
        state.performRedo()
        XCTAssertEqual(state.highlights.first?.color, "blue", "and the one under it is still there")
        XCTAssertFalse(state.undoManager.canRedo)
    }

    /// An undo started without `performUndo` is put back on the next turn
    /// of the run loop.
    @MainActor
    func testAFailedUndoStartedElsewhereIsPutBackToo() throws {
        let session = try session()
        let state = session.state
        _ = try threeColors(session)
        state.performUndo()
        nextEvent()
        try breakFile(session.paths.eventLog)

        state.undoManager.undo()
        nextEvent()

        XCTAssertEqual(state.highlights.first?.color, "green")
        XCTAssertEqual(state.undoManager.undoActionName, "Change Highlight Color")
        XCTAssertEqual(state.undoManager.redoActionName, "Change Highlight Color")
        try repairFile(session.paths.eventLog)
        state.performRedo()
        XCTAssertEqual(state.highlights.first?.color, "blue")
    }

    /// Codex's case for groups: a color change and the deletion of the same
    /// highlight with no event between them (where NSUndoManager's grouping
    /// by event would fold them into one undo group). Each is its own step,
    /// so a failed restore loses nothing: once the disk recovers, ⌘Z restores
    /// the highlight in green, and the next ⌘Z gives the yellow it had before.
    @MainActor
    func testActionsInOneEventStaySeparateUndoSteps() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        state.setHighlightColor(highlight.id, color: "green")
        state.deleteHighlight(highlight.id)
        XCTAssertTrue(state.activeHighlights.isEmpty)
        try breakFile(session.paths.eventLog)

        state.performUndo()
        XCTAssertTrue(state.activeHighlights.isEmpty, "the restore could not be saved")
        XCTAssertEqual(state.undoManager.undoActionName, "Remove Highlight")

        try repairFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.first?.color, "green", "restored as it was when removed")
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.first?.color, "yellow", "and the color change is its own step")
        XCTAssertEqual(try highlightsOnDisk(session).first?.color, "yellow")
    }

    /// Codex's case for a pending recovery: an undo started outside ⌘Z fails
    /// and, before its recovery has run, ⌘Z arrives. The recovery runs first,
    /// so ⌘Z undoes blue to green, not green to yellow.
    @MainActor
    func testUndoWaitsForAPendingRecovery() throws {
        let session = try session()
        let state = session.state
        _ = try threeColors(session)
        try breakFile(session.paths.eventLog)

        state.undoManager.undo()
        XCTAssertEqual(state.highlights.first?.color, "blue")
        try repairFile(session.paths.eventLog)
        state.performUndo()

        XCTAssertEqual(state.highlights.first?.color, "green")
        state.performUndo()
        XCTAssertEqual(state.highlights.first?.color, "yellow")
    }

    /// Two failed undos started outside ⌘Z before either recovery runs: both
    /// entries go back, in their order, and the redo stack is untouched.
    @MainActor
    func testTwoPendingRecoveriesBothComeBackInOrder() throws {
        let session = try session()
        let state = session.state
        _ = try threeColors(session)
        try breakFile(session.paths.eventLog)

        state.undoManager.undo()
        state.undoManager.undo()
        XCTAssertEqual(state.highlights.first?.color, "blue")
        try repairFile(session.paths.eventLog)

        state.performUndo()
        XCTAssertEqual(state.highlights.first?.color, "green")
        state.performUndo()
        XCTAssertEqual(state.highlights.first?.color, "yellow")
        state.performRedo()
        state.performRedo()
        XCTAssertEqual(state.highlights.first?.color, "blue")
        XCTAssertFalse(state.undoManager.canRedo)
        nextEvent()
        XCTAssertEqual(state.highlights.first?.color, "blue", "nothing left to run later")
    }

    /// The undo of an edit restores the comment's time as well as its text,
    /// also when it is retried after a failure.
    @MainActor
    func testARetriedUndoOfAnEditRestoresItsTime() throws {
        let session = try session()
        let state = session.state
        let comment = try savedComment(session)
        state.updateComment(comment.id, verbatim: "Is this really identified?")
        nextEvent()
        try breakFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.comments.first?.verbatim, "Is this really identified?")

        try repairFile(session.paths.eventLog)
        state.performUndo()
        XCTAssertEqual(state.comments.first?.verbatim, "Is this identified?")
        XCTAssertEqual(state.comments.first?.updatedAt, comment.updatedAt)
    }

    // MARK: Regions and the session format

    /// A region raises the session to version 2, in memory and on disk, and
    /// removing it does not lower it.
    @MainActor
    func testARegionRaisesTheSessionVersionForGood() throws {
        let session = try session()
        let state = session.state
        let page = try XCTUnwrap(session.document.page(at: 0))
        XCTAssertEqual(state.manifest?.schemaVersion, 1)
        _ = try savedHighlight(session)
        XCTAssertEqual(try SessionRepository().loadSession(at: session.paths.root).manifest.schemaVersion, 1, "text highlights keep version 1")

        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        XCTAssertEqual(state.manifest?.schemaVersion, 2)
        XCTAssertEqual(try SessionRepository().loadSession(at: session.paths.root).manifest.schemaVersion, 2)

        nextEvent()
        state.deleteHighlight(region.id)
        XCTAssertEqual(try SessionRepository().loadSession(at: session.paths.root).manifest.schemaVersion, 2)
    }

    /// A first region whose journal event fails after session.json (2) and
    /// highlights.json (with the region) were written: the rollback writes
    /// the records without it and only then session.json, back at 1, so
    /// older builds can open the session again.
    @MainActor
    func testARolledBackFirstRegionEndsAtVersionOne() throws {
        let session = try session()
        let state = session.state
        let page = try XCTUnwrap(session.document.page(at: 0))
        try breakFile(session.paths.eventLog)

        XCTAssertNil(state.createRegion(on: page, rect: FigurePDF.figure))

        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertTrue(try highlightsOnDisk(session).isEmpty)
        XCTAssertFalse(try XCTUnwrap(state.errorMessage).contains("could not be put back"), "the rollback worked")
        XCTAssertEqual(try versionOnDisk(session), 1)
        XCTAssertEqual(state.manifest?.schemaVersion, 1)
    }

    /// The rollback itself fails part way (comments.json, after it wrote
    /// highlights.json without the region): session.json is written last
    /// when lowering, so it still says 2. A 2 without a region is only a
    /// leftover; the next save that works lowers it.
    @MainActor
    func testARollbackThatFailsPartWayLeavesTheGuardUp() throws {
        let session = try session()
        let state = session.state
        let page = try XCTUnwrap(session.document.page(at: 0))
        try breakFile(session.paths.comments)

        XCTAssertNil(state.createRegion(on: page, rect: FigurePDF.figure))

        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertTrue(try highlightsOnDisk(session).isEmpty)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the region:"), message)
        XCTAssertTrue(message.contains("could not be put back"), message)
        XCTAssertEqual(try versionOnDisk(session), 2, "not lowered by a save that did not finish")

        try repairFile(session.paths.comments)
        state.saveNotes()
        XCTAssertEqual(try versionOnDisk(session), 1, "the next save lowers it")
    }

    /// highlights.json cannot be written at all: the region never reached
    /// it, session.json keeps the 2 written before it, and the next save
    /// that works lowers it.
    @MainActor
    func testAFirstRegionThatNeverReachesHighlightsLeavesALeftoverTwo() throws {
        let session = try session()
        let state = session.state
        let page = try XCTUnwrap(session.document.page(at: 0))
        let before = try highlightsOnDisk(session)
        try breakFile(session.paths.highlights)

        XCTAssertNil(state.createRegion(on: page, rect: FigurePDF.figure))

        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertEqual(try versionOnDisk(session), 2)
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).contains("could not be put back"))
        try repairFile(session.paths.highlights)
        state.saveNotes()
        XCTAssertEqual(try versionOnDisk(session), 1)
        XCTAssertEqual(try highlightsOnDisk(session), before)
    }

    @MainActor
    private func versionOnDisk(_ session: RegionTestSession) throws -> Int {
        try JSONDecoder.paperCompanion.decode(SessionManifest.self, from: Data(contentsOf: session.paths.manifest)).schemaVersion
    }

    // MARK: Success is unchanged

    /// The same events, in the same order, with the same undo names and
    /// status messages as before this stage.
    @MainActor
    func testSuccessfulActionsJournalAsBefore() throws {
        let session = try session()
        let state = session.state
        let highlight = try savedHighlight(session)
        XCTAssertEqual(state.statusMessage, "Highlight saved · page 1")
        XCTAssertEqual(state.undoManager.undoActionName, "Highlight")
        let comment = try savedComment(session, linkedTo: highlight)
        XCTAssertEqual(state.statusMessage, "Comment linked to highlighted text · visible under Saved comments")
        state.updateComment(comment.id, verbatim: "Edited")
        XCTAssertEqual(state.statusMessage, "Comment updated")
        XCTAssertEqual(state.undoManager.undoActionName, "Edit Comment")
        nextEvent()
        state.setHighlightColor(highlight.id, color: "green")
        XCTAssertEqual(state.undoManager.undoActionName, "Change Highlight Color")
        nextEvent()
        state.deleteComment(comment.id)
        XCTAssertEqual(state.statusMessage, "Comment deleted · ⌘Z to undo")
        XCTAssertEqual(state.undoManager.undoActionName, "Delete Comment")
        nextEvent()
        state.performUndo()
        XCTAssertEqual(state.statusMessage, "Comment restored")
        nextEvent()
        state.deleteHighlight(highlight.id)
        XCTAssertEqual(state.statusMessage, "Highlight and linked comments removed · ⌘Z to undo")
        XCTAssertEqual(state.undoManager.undoActionName, "Remove Highlight")
        nextEvent()
        state.performUndo()
        XCTAssertEqual(state.statusMessage, "Highlight restored")
        XCTAssertNil(state.errorMessage)

        XCTAssertEqual(try journalKinds(session), [
            "session_created", "highlight_created", "comment_created", "comment_updated",
            "highlight_color_changed", "comment_deleted", "comment_restored", "highlight_deleted", "highlight_restored",
        ])
        XCTAssertEqual(try journal(session).filter { $0.kind.hasPrefix("comment") }.map(\.recordID), Array(repeating: comment.id, count: 4))
    }
}
