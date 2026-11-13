import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

final class SidebarInteractionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // AppState stores auto-highlight in the standard defaults; put the
        // test process's value back as it was, absence included.
        restoreStandardDefaultsAfterTest()
        // The real pointer on this Mac must not decide the result.
        pinPointerStateForTest()
    }

    // MARK: Fixtures

    private static let passage = "A theoretically important passage"

    @MainActor
    private static func textPDF() -> PDFDocument {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        view.string = "The first sentence of the paper is here. \(passage) follows. Then more text to close the page."
        return PDFDocument(data: view.dataWithPDF(inside: view.bounds))!
    }

    private func selection(page: Int = 4, label: String = "5", text: String = passage, offset: Int = 30) -> SelectionSnapshot {
        SelectionSnapshot(
            selectedText: text,
            prefix: "Before. ",
            suffix: " After.",
            locations: [
                HighlightLocation(
                    pageIndex: page, pageLabel: label,
                    lineRects: [RectRecord(x: 10, y: 20, width: 100, height: 12)],
                    textRanges: [TextRangeRecord(location: offset, length: text.count)]
                )
            ]
        )
    }

    @MainActor
    private func makeState() -> AppState {
        let state = AppState()
        state.autoHighlightEnabled = false
        return state
    }

    private func escapeKey(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    /// SwiftUI content in an offscreen window that is never shown.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let host: NSView

        init<V: View>(state: AppState, content: V, width: CGFloat = 960) {
            let hosting = NSHostingView(rootView: content.environmentObject(state))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 760)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            host = hosting
            hosting.layoutSubtreeIfNeeded()
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// The PDF reader and the inspector side by side, as in the app window.
    @MainActor
    private func readerHarness(_ state: AppState) -> Harness {
        Harness(state: state, content: HStack(spacing: 0) {
            PDFReaderView(state: state).frame(width: 520)
            InspectorView().frame(width: 420)
        })
    }

    // MARK: Composer focus request (item 6)

    @MainActor
    func testAddHighlightRequestsComposerFocusAndShowsAnnotations() {
        let state = makeState()
        state.inspectorTab = .agent
        state.currentSelection = selection()

        state.addHighlight()

        XCTAssertNotNil(state.commentFocusRequestID)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertNotNil(state.takeCommentFocusRequest(), "a composer can take the request")
        XCTAssertNil(state.takeCommentFocusRequest(), "but only one, once")
    }

    @MainActor
    func testAutoHighlightRequestsComposerFocus() {
        let state = makeState()
        state.autoHighlightEnabled = true
        defer { state.autoHighlightEnabled = false }

        state.selectionChanged(selection())
        spin(0.5)

        XCTAssertEqual(state.activeHighlights.count, 1, "auto-highlight fired")
        XCTAssertNotNil(state.commentFocusRequestID)
        XCTAssertNotNil(state.takeCommentFocusRequest())
    }

    @MainActor
    func testExistingHighlightsAndCommentAnchorsDoNotMoveFocus() {
        let state = makeState()
        state.currentSelection = selection()
        state.addHighlight()
        let highlight = state.activeHighlights[0]
        _ = state.takeCommentFocusRequest()
        let request = state.commentFocusRequestID

        state.addHighlight()
        XCTAssertEqual(state.commentFocusRequestID, request, "re-highlighting the same text makes nothing new")

        state.selectionChanged(nil)
        state.highlightClicked(highlight.id)
        XCTAssertEqual(state.commentFocusRequestID, request, "a click in the PDF leaves the keyboard there")

        state.clearEntrySelection()
        state.selectEntry(state.annotationEntries[0])
        XCTAssertEqual(state.commentFocusRequestID, request, "a card click leaves the keyboard in the PDF")

        state.selectionChanged(selection(text: "Another sentence entirely", offset: 200))
        state.commentDraft = "Linked by saving"
        state.saveCommentFromKeyboard()
        XCTAssertEqual(state.activeHighlights.count, 2, "saving made a comment-anchor highlight")
        XCTAssertEqual(state.commentFocusRequestID, request, "the comment-anchor highlight does not ask for focus")
        XCTAssertNil(state.takeCommentFocusRequest())
    }

    /// The whole path in real views: a PDF selection is highlighted while the
    /// Annotations tab is hidden; the tab switches, the comment box takes the
    /// keyboard, the PDF selection survives the focus change, and ⌘↩ saves a
    /// comment linked to the new highlight.
    @MainActor
    func testNewHighlightPutsCursorInComposerAndStaysLinked() throws {
        let state = makeState()
        state.document = Self.textPDF()
        state.inspectorTab = .agent
        let harness = readerHarness(state)
        defer { harness.close() }
        spin()
        let pdfView = try XCTUnwrap(descendants(of: harness.host, as: HighlightClickPDFView.self).first)
        harness.window.makeFirstResponder(pdfView)
        let match = try XCTUnwrap(pdfView.document?.findString(Self.passage, withOptions: .caseInsensitive).first)
        pdfView.setCurrentSelection(match, animate: false)
        XCTAssertEqual(state.currentSelection?.selectedText, Self.passage)
        XCTAssertTrue(descendants(of: harness.host, as: CommentTextView.self).isEmpty, "Annotations tab not showing")

        state.addHighlight()
        spin(0.5)

        let highlightID = try XCTUnwrap(state.selectedHighlightID)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertTrue(harness.window.firstResponder is CommentTextView, "the comment box has the keyboard")
        XCTAssertEqual(state.selectedHighlightID, highlightID, "moving focus off the PDF kept the highlight selected")
        XCTAssertNotNil(state.currentSelection, "and kept the PDF selection")

        state.commentDraft = "Typed straight after highlighting"
        state.saveCommentFromKeyboard()
        XCTAssertEqual(state.comments.last?.highlightID, highlightID)
        XCTAssertEqual(state.activeHighlights.count, 1, "no second highlight from the still-live selection")
    }

    /// The owner's must-keep: clicking an existing highlight and pressing ⌫
    /// deletes it. The keyboard stays in the PDF and the composer does not
    /// take it.
    @MainActor
    func testDeleteKeyStillRemovesAClickedHighlight() throws {
        let state = makeState()
        state.document = Self.textPDF()
        let harness = readerHarness(state)
        defer { harness.close() }
        spin()
        let pdfView = try XCTUnwrap(descendants(of: harness.host, as: HighlightClickPDFView.self).first)
        let match = try XCTUnwrap(pdfView.document?.findString(Self.passage, withOptions: .caseInsensitive).first)
        pdfView.setCurrentSelection(match, animate: false)
        state.addHighlight()
        let highlightID = try XCTUnwrap(state.selectedHighlightID)
        spin(0.5)
        state.commentDraft = "Linked"
        state.saveCommentFromKeyboard()

        // What HighlightClickPDFView.mouseDown does on a click on a highlight.
        pdfView.clearSelection()
        harness.window.makeFirstResponder(pdfView)
        pdfView.onHighlightClick?(highlightID)
        spin()

        XCTAssertEqual(state.selectedHighlightID, highlightID)
        XCTAssertTrue(harness.window.firstResponder === pdfView, "the keyboard stays in the PDF")
        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        pdfView.keyDown(with: delete)

        XCTAssertTrue(state.activeHighlights.isEmpty)
        XCTAssertTrue(state.activeComments.isEmpty, "its comment went with it")
        state.performUndo()
        XCTAssertEqual(state.activeHighlights.map(\.id), [highlightID])
    }

    @MainActor
    func testEscapeInComposerReturnsToPDFOnlyWhenTheDraftIsEmpty() throws {
        let state = makeState()
        state.document = Self.textPDF()
        let harness = readerHarness(state)
        defer { harness.close() }
        spin()
        let pdfView = try XCTUnwrap(descendants(of: harness.host, as: HighlightClickPDFView.self).first)
        let textView = try XCTUnwrap(descendants(of: harness.host, as: CommentTextView.self).first)
        let escape = try escapeKey(in: harness.window)

        harness.window.makeFirstResponder(textView)
        textView.insertText("half a thought", replacementRange: textView.selectedRange())
        XCTAssertEqual(state.commentDraft, "half a thought")
        textView.keyDown(with: escape)
        spin()
        XCTAssertTrue(harness.window.firstResponder === textView, "Esc with a draft does nothing")
        XCTAssertEqual(state.commentDraft, "half a thought")

        textView.selectAll(nil)
        textView.deleteBackward(nil)
        XCTAssertEqual(state.commentDraft, "")
        textView.keyDown(with: escape)
        spin()
        XCTAssertTrue(harness.window.firstResponder === pdfView, "Esc in an empty box hands the keyboard to the PDF")
    }

    // MARK: Search (item 5)

    @MainActor
    func testFindInCommentsFocusesTheSearchFieldAndEscClearsIt() throws {
        let state = makeState()
        state.document = Self.textPDF()
        state.currentSelection = selection()
        state.addHighlight()
        _ = state.takeCommentFocusRequest()
        state.inspectorTab = .notes
        let harness = readerHarness(state)
        defer { harness.close() }
        spin()

        state.findInComments()
        spin(0.5)

        XCTAssertEqual(state.inspectorTab, .annotations)
        let field = try XCTUnwrap(descendants(of: harness.host, as: WindowAwareSearchField.self).first)
        let editor = try XCTUnwrap(harness.window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === field, "the search field is being edited")

        editor.insertText("passage", replacementRange: editor.selectedRange())
        XCTAssertEqual(state.annotationSearchQuery, "passage")
        editor.keyDown(with: try escapeKey(in: harness.window))
        spin()
        XCTAssertEqual(state.annotationSearchQuery, "", "Esc clears the search")
    }

    /// The handoff to the comment box waits while the mouse is down, then
    /// checks the request again: it focuses only if the request is still the
    /// current one for the still-selected highlight, and gives up if the mouse
    /// stays down for the request's whole life.
    @MainActor
    func testDeferredComposerFocusIsRevalidatedAndNeverForced() throws {
        var mouseDown = false
        let realMouse = KeyboardFocus.mouseIsDown
        KeyboardFocus.mouseIsDown = { mouseDown }
        defer { KeyboardFocus.mouseIsDown = realMouse }

        let state = makeState()
        let harness = Harness(state: state, content: CommentComposer().frame(width: 420, height: 300), width: 420)
        defer { harness.close() }
        spin()
        func composerHasKeyboard() -> Bool { harness.window.firstResponder is CommentTextView }

        // Released in time, request still current: focus moves.
        mouseDown = true
        state.currentSelection = selection(offset: 10)
        state.addHighlight()
        spin(0.3)
        XCTAssertFalse(composerHasKeyboard(), "nothing moves while the button is down")
        mouseDown = false
        spin(0.3)
        XCTAssertTrue(composerHasKeyboard())

        // The selection moved on before the button came up: the highlight the
        // request was made for is no longer selected, so nothing happens.
        harness.window.makeFirstResponder(nil)
        mouseDown = true
        state.selectionChanged(selection(text: "Second passage", offset: 300))
        state.addHighlight()
        spin(0.3)
        state.selectionChanged(selection(text: "Third passage, still dragging", offset: 600))
        mouseDown = false
        spin(0.3)
        XCTAssertFalse(composerHasKeyboard(), "a stale request does not take the keyboard")

        // The button stays down for the request's whole life: give up, and do
        // not grab the keyboard when it finally comes up.
        harness.window.makeFirstResponder(nil)
        mouseDown = true
        state.selectionChanged(selection(text: "Fourth passage", offset: 900))
        state.addHighlight()
        spin(AppState.focusRequestLifetime + 0.4)
        XCTAssertFalse(composerHasKeyboard(), "no focus forced during a drag that is still going")
        mouseDown = false
        spin(0.3)
        XCTAssertFalse(composerHasKeyboard(), "nor after the wait has run out")
    }

    /// Esc in the empty comment box of the separate Reading Notes window hands
    /// the keyboard to the PDF in the main window and makes that window key.
    @MainActor
    func testEscapeInNotesWindowComposerReturnsKeyboardToThePDFWindow() throws {
        final class RecordingWindow: NSWindow {
            var makeKeyCalls = 0
            override func makeKey() {
                makeKeyCalls += 1
                super.makeKey()
            }
        }
        let state = makeState()
        state.document = Self.textPDF()
        let readerHost = NSHostingView(rootView: PDFReaderView(state: state).frame(width: 520, height: 700))
        readerHost.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        let mainWindow = RecordingWindow(contentRect: readerHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.contentView = readerHost
        let notes = Harness(state: state, content: NotesWindowView().frame(width: 440, height: 580), width: 440)
        defer {
            notes.close()
            mainWindow.contentView = nil
            mainWindow.close()
        }
        readerHost.layoutSubtreeIfNeeded()
        spin()
        let pdfView = try XCTUnwrap(descendants(of: readerHost, as: HighlightClickPDFView.self).first)
        let textView = try XCTUnwrap(descendants(of: notes.host, as: CommentTextView.self).first)
        mainWindow.makeFirstResponder(nil)
        notes.window.makeFirstResponder(textView)

        textView.keyDown(with: try escapeKey(in: notes.window))
        spin()

        XCTAssertTrue(mainWindow.firstResponder === pdfView, "the PDF has the main window's keyboard")
        XCTAssertGreaterThan(mainWindow.makeKeyCalls, 0, "and its window was made key")
    }

    @MainActor
    func testNewHighlightIsRevealedAndAHidingSearchCleared() {
        let state = makeState()
        state.annotationSearchQuery = "theoretically"
        state.currentSelection = selection()
        let reveal = state.sidebarRevealRequestID
        state.addHighlight()
        let first = state.activeHighlights[0]
        XCTAssertEqual(state.sidebarRevealID, first.id)
        XCTAssertNotEqual(state.sidebarRevealRequestID, reveal)
        XCTAssertEqual(state.annotationSearchQuery, "theoretically", "a search that shows the new card stays")

        state.annotationSearchQuery = "unrelated words"
        state.selectionChanged(selection(text: "Another passage", offset: 400))
        state.addHighlight()
        let second = state.activeHighlights[1]
        XCTAssertEqual(state.sidebarRevealID, second.id)
        XCTAssertEqual(state.annotationSearchQuery, "", "a search that hides the new card is cleared")

        let before = state.sidebarRevealRequestID
        state.addHighlight()
        XCTAssertEqual(state.sidebarRevealRequestID, before, "re-highlighting existing text reveals nothing new")
    }

    @MainActor
    func testClickingAHighlightHiddenBySearchClearsTheSearch() {
        let state = makeState()
        state.currentSelection = selection()
        state.addHighlight()
        let highlight = state.activeHighlights[0]
        state.selectionChanged(nil)

        state.annotationSearchQuery = "theoretically"
        state.highlightClicked(highlight.id)
        XCTAssertEqual(state.annotationSearchQuery, "theoretically", "a search that shows the card stays")

        state.clearEntrySelection()
        state.annotationSearchQuery = "unrelated words"
        let reveal = state.sidebarRevealRequestID
        state.highlightClicked(highlight.id)
        XCTAssertEqual(state.annotationSearchQuery, "", "a search that hides the card is cleared")
        XCTAssertNotEqual(state.sidebarRevealRequestID, reveal)
        XCTAssertEqual(state.sidebarRevealID, highlight.id)
    }

    // MARK: Click target (item 1)

    /// Selectable text puts an AppKit text view over the words, and that view
    /// takes the click before the card's tap gesture sees it: the "only the
    /// header line expands it" bug. On a collapsed card nothing may hit-test
    /// to a text view; on an expanded one the text is selectable.
    @MainActor
    func testCollapsedCardIsOneClickTargetAndExpandedTextIsSelectable() throws {
        let state = makeState()
        state.currentSelection = selection()
        state.addHighlight()
        let highlight = state.activeHighlights[0]
        state.comments = [
            CommentRecord(highlightID: highlight.id, pageIndex: 4, pageLabel: "5",
                          verbatim: "A long comment that wraps over more than one line so the body of the card is mostly text."),
        ]
        state.agentReplies = [state.comments[0].id: "An agent reply that is also long enough to wrap onto a second line."]
        let entry = state.annotationEntries[0]

        func hits(expanded: Bool) -> [NSView] {
            let harness = Harness(
                state: state,
                content: AnnotationCard(entry: entry, expanded: expanded)
                    .frame(width: 380, height: 200, alignment: .top),
                width: 380
            )
            defer { harness.close() }
            spin()
            var views: [NSView] = []
            for x in stride(from: 20.0, through: 300, by: 10) {
                for y in stride(from: 4.0, through: 196, by: 4) {
                    if let hit = harness.host.hitTest(NSPoint(x: x, y: y)) { views.append(hit) }
                }
            }
            return views
        }

        func isText(_ view: NSView) -> Bool { view is NSText || view is NSTextField }

        let collapsed = hits(expanded: false)
        XCTAssertFalse(collapsed.isEmpty)
        XCTAssertFalse(collapsed.contains(where: isText), "nothing on a collapsed card takes the click from it")

        let expanded = hits(expanded: true)
        XCTAssertTrue(expanded.contains(where: isText), "expanded text is selectable")
    }

    // MARK: Real clicks (item 1)

    /// Clicks anywhere on a collapsed card select and expand it: on the
    /// comment text (both lines), on the quote of a highlight with no comment,
    /// on the marker, and on the strip above the text where the old header
    /// line was. A button inside a card still gets its own click.
    @MainActor
    func testRealClicksAnywhereOnACollapsedCardSelectIt() throws {
        let state = makeState()
        let commented = HighlightRecord(
            quote: "Highlighted passage with a comment", prefix: "", suffix: "",
            locations: [selection(page: 0, label: "1", offset: 10).locations[0]],
            createdAt: Date(timeIntervalSince1970: 1))
        let quoteOnly = HighlightRecord(
            quote: "Bravo quote of a highlight that has no comment and wraps onto a second line in the card",
            prefix: "", suffix: "",
            locations: [selection(page: 0, label: "1", offset: 400).locations[0]],
            color: "green", createdAt: Date(timeIntervalSince1970: 2))
        let comment = CommentRecord(
            highlightID: commented.id, pageIndex: 0, pageLabel: "1",
            verbatim: "Alpha comment text that is long enough to wrap onto a second line of the card body",
            createdAt: Date(timeIntervalSince1970: 3))
        let pageComment = CommentRecord(
            pageIndex: 1, pageLabel: "2", verbatim: "Charlie page comment",
            createdAt: Date(timeIntervalSince1970: 4))
        state.highlights = [commented, quoteOnly]
        state.comments = [comment, pageComment]
        // Reading order of the cards, top to bottom.
        let cardIDs = [commented.id, quoteOnly.id, pageComment.id]

        let host = NSHostingView(rootView: AnnotationsView().environmentObject(state).frame(width: 420, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        let window = offscreenWindow(for: host)
        defer { closeOffscreenWindow(window) }
        spin()

        // Where things are, read from the real view tree: each Text draws in a
        // CGDrawingView, each marker in a small graphics view at the leading
        // edge. Page headers are the texts at the far left.
        let list = try XCTUnwrap(descendants(of: host, as: NSScrollView.self).first { $0.documentView != nil })
        let document = try XCTUnwrap(list.documentView)
        func layout() -> (texts: [NSRect], glyphs: [NSRect]) {
            let views = descendants(of: document, as: NSView.self).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            let frames = views.map { (name: String(describing: type(of: $0)), frame: $0.convert($0.bounds, to: nil)) }
            let documentLeft = document.convert(document.bounds, to: nil).minX
            // SwiftUI sometimes draws one Text in two views with the same frame.
            var texts: [NSRect] = []
            for frame in frames where frame.name == "CGDrawingView" && frame.frame.minX - documentLeft > 30
                && !texts.contains(frame.frame) {
                texts.append(frame.frame)
            }
            texts.sort { $0.maxY > $1.maxY }  // window coordinates: top first
            let glyphs = frames.filter { $0.name != "CGDrawingView" && $0.frame.width <= 14 && $0.frame.height <= 14 }.map(\.frame)
            return (texts, glyphs)
        }
        let (texts, glyphs) = layout()
        XCTAssertEqual(texts.count, 3, "one text per card: \(texts)")
        guard texts.count == 3 else { return }
        func center(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
        func marker(beside text: NSRect, among glyphs: [NSRect] = glyphs) -> NSRect? {
            glyphs.filter { $0.maxX < text.minX && abs($0.maxY - text.maxY) < 8 }.min { $0.minX < $1.minX }
        }
        let commentText = texts[0], quoteText = texts[1], pageText = texts[2]
        let pageMarker = try XCTUnwrap(marker(beside: pageText), "page marker beside \(pageText) among \(glyphs)")
        let swatch = try XCTUnwrap(marker(beside: commentText), "swatch beside \(commentText)")
        func isText(_ view: NSView?) -> Bool { view is NSText || view is NSTextField }

        let cases: [(String, NSPoint, UUID)] = [
            ("comment text", center(commentText), cardIDs[0]),
            ("second line of the comment text", NSPoint(x: commentText.minX + 30, y: commentText.minY + 6), cardIDs[0]),
            ("quote of a highlight with no comment", center(quoteText), cardIDs[1]),
            ("page marker", center(pageMarker), cardIDs[2]),
            ("highlight swatch", center(swatch), cardIDs[0]),
            ("header strip above the text", NSPoint(x: commentText.minX + 40, y: commentText.maxY + 4), cardIDs[0]),
        ]
        // The classes AppKit will ask, read from the real hit-test, plus the
        // text classes behind selectable text so that, on the old code, the
        // text overlay gets its click too.
        let frameView = try XCTUnwrap(host.superview)
        var hitClasses: [AnyClass] = [NSTextView.self, NSTextField.self]
        for (_, point, _) in cases {
            if let hit = frameView.hitTest(frameView.convert(point, from: nil)),
               !hitClasses.contains(where: { $0 == type(of: hit) }) {
                hitClasses.append(type(of: hit))
            }
        }
        try withFirstMouseAccepted(by: hitClasses) {
            for (name, point, expected) in cases {
                state.clearEntrySelection()
                spin(0.2)
                XCTAssertNil(state.selectedEntryID)
                click(atWindowPoint: point, in: window)
                XCTAssertEqual(state.selectedEntryID, expected, "a click on the \(name) selects its card")
            }

            // The last click expanded the commented card; its text is now
            // selectable, so the same point hit-tests to a text view.
            let expandedText = layout().texts[0]
            let hit = frameView.hitTest(frameView.convert(center(expandedText), from: nil))
            XCTAssertTrue(isText(hit), "the expanded card's text is selectable (hit \(String(describing: hit)))")

            // The delete button of the expanded comment still gets its click:
            // the trash glyph is the rightmost small view on the text's top line.
            let trash = try XCTUnwrap(
                layout().glyphs.filter { $0.minX > expandedText.maxX && abs($0.midY - (expandedText.maxY - 10)) < 8 }
                    .max { $0.minX < $1.minX },
                "trash glyph")
            click(atWindowPoint: center(trash), in: window)
            XCTAssertFalse(state.activeComments.contains { $0.id == comment.id }, "the delete button deleted the comment")
            XCTAssertTrue(state.activeComments.contains { $0.id == pageComment.id })
            XCTAssertEqual(state.selectedEntryID, commented.id, "the button's click did not also click the card")

            // A double-click on a collapsed card leaves it open: the second
            // click comes within the double-click interval of the one that
            // expanded it. A single click later still collapses it.
            state.clearEntrySelection()
            spin(0.2)
            let now = layout()
            XCTAssertEqual(now.texts.count, 3)
            let pageSwatch = try XCTUnwrap(marker(beside: now.texts[2], among: now.glyphs), "page marker")
            click(atWindowPoint: center(pageSwatch), in: window, clickCount: 1, settle: 0.08)
            XCTAssertEqual(state.selectedEntryID, pageComment.id)
            click(atWindowPoint: center(pageSwatch), in: window, clickCount: 2, settle: 0.3)
            XCTAssertEqual(state.selectedEntryID, pageComment.id, "a double-click leaves the card open")
            spin(NSEvent.doubleClickInterval)
            click(atWindowPoint: center(pageSwatch), in: window)
            XCTAssertNil(state.selectedEntryID, "a later single click on the open card's marker collapses it")
        }
    }

    // MARK: Esc on the list

    @MainActor
    func testEscapeCollapsesOnlyWhenTheKeyboardIsNotInText() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close(); window.close() }
        let pdfView = PDFView()
        let textView = NSTextView()

        func check(_ code: UInt16 = 53, _ modifiers: NSEvent.ModifierFlags = [], in eventWindow: NSWindow? = nil,
                   responder: NSResponder?, enabled: Bool = true) -> Bool {
            EscapeKeyMonitor.shouldCollapse(keyCode: code, modifiers: modifiers, eventWindow: eventWindow ?? window,
                                            ownWindow: window, firstResponder: responder, isEnabled: enabled)
        }

        XCTAssertTrue(check(responder: pdfView))
        XCTAssertTrue(check(responder: window))
        XCTAssertFalse(check(responder: textView), "Esc in the comment box or search field is theirs")
        XCTAssertFalse(check(responder: pdfView, enabled: false), "nothing selected")
        XCTAssertFalse(check(36, responder: pdfView), "only Esc")
        XCTAssertFalse(check(53, [.command], responder: pdfView))
        XCTAssertFalse(check(in: other, responder: pdfView), "another window")

        let readOnly = NSTextView()
        readOnly.isEditable = false
        XCTAssertTrue(check(responder: readOnly), "text selected in an expanded card is read-only; Esc still collapses")
        let fieldEditor = window.fieldEditor(true, for: nil)
        XCTAssertFalse(check(responder: fieldEditor), "the search field's editor keeps Esc")
    }
}
