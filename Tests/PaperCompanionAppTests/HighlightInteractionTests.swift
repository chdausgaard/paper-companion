import AppKit
import PDFKit
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

final class HighlightInteractionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // AppState stores auto-highlight in the standard defaults; put the
        // test process's value back as it was, absence included.
        restoreStandardDefaultsAfterTest()
    }

    // MARK: Fixtures

    static let pages = [
        """
        Alpha passage opens the page.

        Plain words that nobody highlighted fill this line.

        Bravo passage follows here.

        Charlie passage is third.

        Delta passage is fourth.

        Echo passage is fifth.

        Selectable sentence for the drag test lives here.
        """,
        """
        Foxtrot passage on page two.

        Golf passage on page two.

        Hotel passage on page two.
        """,
    ]
    static let passages = ["Alpha passage", "Bravo passage", "Charlie passage", "Delta passage",
                           "Echo passage", "Foxtrot passage", "Golf passage", "Hotel passage"]

    @MainActor
    private func makeState() -> AppState {
        let state = AppState()
        state.autoHighlightEnabled = false
        state.document = TestPDF.make(pages: Self.pages, size: NSSize(width: 500, height: 420))
        return state
    }

    /// A reader with the given passages highlighted, the keyboard in the PDF
    /// and nothing selected or hovered.
    @MainActor
    private func reader(highlighting passages: [String]) throws -> (ReaderHarness, [UUID]) {
        let harness = try ReaderHarness(test: self, state: makeState())
        let colors = ["yellow", "green", "blue", "pink"]
        var ids: [UUID] = []
        for (index, passage) in passages.enumerated() {
            ids.append(try harness.highlight(passage, color: colors[index % colors.count], test: self))
        }
        // Let the composer take its focus request, then give the keyboard back.
        spin(0.4)
        harness.window.makeFirstResponder(harness.pdfView)
        return (harness, ids)
    }

    private struct Drawn: Equatable {
        let objects: [ObjectIdentifier]
        let colors: [NSColor]
    }

    @MainActor
    private func drawn(_ harness: ReaderHarness) -> [UUID: Drawn] {
        harness.annotations().mapValues { Drawn(objects: $0.map(ObjectIdentifier.init), colors: $0.map(\.color)) }
    }

    /// Gives every drawn annotation a fill no code path produces, so that
    /// any restyle of it, even to the color it already had, shows. Returns
    /// the marked state.
    @MainActor
    private func markEveryAnnotation(_ harness: ReaderHarness) -> [UUID: Drawn] {
        for annotations in harness.annotations().values {
            for annotation in annotations { annotation.color = annotation.color.withAlphaComponent(Self.untouchedAlpha) }
        }
        return drawn(harness)
    }

    static let untouchedAlpha: CGFloat = 0.401

    @MainActor
    private func alpha(of id: UUID, in harness: ReaderHarness) -> CGFloat? {
        harness.annotations()[id]?.first?.color.alphaComponent
    }

    private func cursorName(_ cursor: NSCursor) -> String {
        switch cursor {
        case NSCursor.pointingHand: return "pointing hand"
        case NSCursor.iBeam: return "I-beam"
        case NSCursor.arrow: return "arrow"
        default: return "other (\(cursor))"
        }
    }

    // MARK: Unchanged keyboard and menu behaviour

    @MainActor
    func testBackspaceAndForwardDeleteReachSelectedEntry() {
        let view = HighlightClickPDFView()
        var calls = 0
        view.onDeleteKey = { calls += 1; return true }
        for code: UInt16 in [51, 117] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: code == 117 ? [.function] : [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testContextMenuActionsTargetSavedHighlight() {
        let view = HighlightClickPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        document.insert(page, at: 0)
        view.document = document
        view.layoutDocumentView()
        let id = UUID()
        let annotation = PDFAnnotation(bounds: NSRect(x: 50, y: 50, width: 100, height: 20), forType: .highlight, withProperties: nil)
        annotation.userName = "PaperCompanion:\(id)"
        page.addAnnotation(annotation)
        let point = view.convert(NSPoint(x: 75, y: 60), from: page)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        var selected: UUID?
        var changed: String?
        var deleted: UUID?
        view.onHighlightClick = { selected = $0 }
        view.onHighlightColor = { target, color in XCTAssertEqual(target, id); changed = color }
        view.onHighlightDelete = { deleted = $0 }
        let menu = view.menu(for: event)
        XCTAssertEqual(selected, id)
        guard let green = menu?.items.first(where: { $0.title == "Green" }),
              let delete = menu?.items.last else { return XCTFail("Missing highlight menu") }
        _ = green.target?.perform(green.action, with: green)
        _ = delete.target?.perform(delete.action, with: delete)
        XCTAssertEqual(changed, "green")
        XCTAssertEqual(deleted, id)
    }

    // MARK: Hit testing

    /// The one hit test that clicks, the context menu and hover share: the
    /// highlight under the point, nothing on plain text, blank page, the gap
    /// between pages, or annotations that are not ours.
    @MainActor
    func testHitTestFindsTheHighlightUnderAPoint() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage", "Golf passage"])
        defer { harness.close(self) }
        let view = harness.pdfView
        func viewPoint(_ window: NSPoint) -> NSPoint { view.convert(window, from: nil) }

        for (index, id) in ids.enumerated() {
            XCTAssertEqual(view.annotationID(at: viewPoint(try harness.windowPoint(ofHighlight: id))), id, "highlight \(index)")
        }
        // Both ends of a highlight's line count, just inside its bounds.
        let alpha = try XCTUnwrap(harness.annotations()[ids[0]]?.first)
        let page = try XCTUnwrap(alpha.page)
        for x in [alpha.bounds.minX + 1, alpha.bounds.maxX - 1] {
            XCTAssertEqual(view.annotationID(at: viewPoint(harness.windowPoint(NSPoint(x: x, y: alpha.bounds.midY), on: page))), ids[0])
        }
        XCTAssertNil(view.annotationID(at: viewPoint(harness.windowPoint(NSPoint(x: alpha.bounds.maxX + 6, y: alpha.bounds.midY), on: page))),
                     "just past the end of the line")
        XCTAssertNil(view.annotationID(at: viewPoint(try harness.windowPoint(ofText: "nobody highlighted"))), "plain text")
        XCTAssertNil(view.annotationID(at: viewPoint(harness.windowPoint(NSPoint(x: 250, y: 12), on: page))), "blank page")
        XCTAssertNil(view.annotationID(at: viewPoint(harness.windowPoint(NSPoint(x: 250, y: -4), on: page))), "the gap below the page")

        // The PDF's own annotations and the arrival flash are not ours, even
        // on top of a highlight; the highlight underneath still answers.
        let foreign = PDFAnnotation(bounds: alpha.bounds, forType: .highlight, withProperties: nil)
        page.addAnnotation(foreign)
        let flash = PDFAnnotation(bounds: alpha.bounds, forType: .highlight, withProperties: nil)
        flash.userName = "PaperCompanionFlash"
        page.addAnnotation(flash)
        XCTAssertEqual(view.annotationID(at: viewPoint(try harness.windowPoint(ofHighlight: ids[0]))), ids[0])
        let plain = try XCTUnwrap(view.document?.findString("nobody highlighted", withOptions: .caseInsensitive).first)
        let onPlain = PDFAnnotation(bounds: plain.bounds(for: page), forType: .highlight, withProperties: nil)
        page.addAnnotation(onPlain)
        XCTAssertNil(view.annotationID(at: viewPoint(try harness.windowPoint(ofText: "nobody highlighted"))), "a foreign annotation")
    }

    // MARK: Hover on the page (items 1 and 3)

    /// Real mouse-moved events: the highlight under the pointer brightens and
    /// the cursor is the pointing hand; plain text keeps the I-beam and blank
    /// page the arrow. Each change restyles only the highlight that gained or
    /// lost hover, in place, and moving within one highlight does nothing.
    @MainActor
    func testHoverBrightensOnlyTheHighlightUnderThePointer() throws {
        let (harness, ids) = try reader(highlighting: Self.passages)
        defer { harness.close(self) }
        let view = harness.pdfView
        let window = harness.window
        XCTAssertTrue(window.firstResponder === view)
        let baseline = markEveryAnnotation(harness)
        XCTAssertEqual(baseline.count, Self.passages.count, "every highlight is drawn")
        let annotationCount = baseline.values.reduce(0) { $0 + $1.objects.count }

        // The hover tracking area is installed, alongside PDFView's own.
        XCTAssertTrue(view.trackingAreas.contains { $0.owner === view && $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .inVisibleRect]) })

        var reports: [UUID?] = []
        let wired = view.onAnnotationHoverChange
        view.onAnnotationHoverChange = { id in reports.append(id); wired?(id) }

        /// Everything but `except` is exactly as marked: same objects, and
        /// never restyled.
        func assertUntouched(except: Set<UUID>, _ context: String, line: UInt = #line) {
            let now = drawn(harness)
            XCTAssertEqual(now.values.reduce(0) { $0 + $1.objects.count }, annotationCount, "no annotation added or removed (\(context))", line: line)
            for (id, before) in baseline where !except.contains(id) {
                XCTAssertEqual(now[id], before, "highlight \(ids.firstIndex(of: id) ?? -1) untouched (\(context))", line: line)
            }
            for id in except {
                XCTAssertEqual(now[id]?.objects, baseline[id]?.objects, "restyled in place, not redrawn (\(context))", line: line)
            }
        }

        let alpha = ids[0], bravo = ids[1]
        moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: alpha), in: window)
        XCTAssertEqual(view.hoveredAnnotationID, alpha)
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.57, accuracy: 0.001)
        XCTAssertTrue(harness.state.annotationHover.flag(for: alpha).isHoveredOnPage)
        assertUntouched(except: [alpha], "on alpha")

        // Further along the same highlight: no new report, nothing restyled.
        var along = try harness.windowPoint(ofHighlight: alpha)
        along.x += 12
        moveMouse(toWindowPoint: along, in: window)
        XCTAssertEqual(reports, [alpha], "moving within one highlight reports nothing new")
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")

        moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: bravo), in: window)
        XCTAssertEqual(reports, [alpha, bravo])
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.42, accuracy: 0.001, "alpha back to rest")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: bravo, in: harness)), 0.57, accuracy: 0.001)
        XCTAssertFalse(harness.state.annotationHover.flag(for: alpha).isHoveredOnPage)
        XCTAssertTrue(harness.state.annotationHover.flag(for: bravo).isHoveredOnPage)
        assertUntouched(except: [alpha, bravo], "alpha to bravo")

        moveMouse(toWindowPoint: try harness.windowPoint(ofText: "nobody highlighted"), in: window)
        XCTAssertEqual(reports, [alpha, bravo, nil])
        XCTAssertNil(view.hoveredAnnotationID)
        XCTAssertEqual(cursorName(NSCursor.current), "I-beam", "plain text keeps the I-beam")
        assertUntouched(except: [alpha, bravo], "off the highlights")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: bravo, in: harness)), 0.42, accuracy: 0.001, "bravo back to rest")

        let page = try XCTUnwrap(view.document?.page(at: 0))
        moveMouse(toWindowPoint: harness.windowPoint(NSPoint(x: 250, y: 12), on: page), in: window)
        XCTAssertEqual(cursorName(NSCursor.current), "arrow", "blank page keeps the arrow")
        XCTAssertEqual(reports.count, 3)

        // A highlight on the second page.
        let golf = ids[6]
        moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: golf), in: window)
        XCTAssertEqual(view.hoveredAnnotationID, golf)
        assertUntouched(except: [alpha, bravo, golf], "on golf")
    }

    /// Scrolling moves the pages under a still pointer: the hover follows to
    /// the highlight now under it, without a mouse-moved event.
    @MainActor
    func testScrollingUnderAStillPointerMovesTheHover() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let view = harness.pdfView
        let onAlpha = try harness.windowPoint(ofHighlight: ids[0])
        let onBravo = try harness.windowPoint(ofHighlight: ids[1])
        moveMouse(toWindowPoint: onAlpha, in: harness.window)
        XCTAssertEqual(view.hoveredAnnotationID, ids[0])

        let scrollView = try XCTUnwrap(view.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        let clip = scrollView.contentView
        let shift = clip.convert(onBravo, from: nil).y - clip.convert(onAlpha, from: nil).y
        XCTAssertNotEqual(shift, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + shift))
        scrollView.reflectScrolledClipView(clip)
        spin(0.05)
        XCTAssertEqual(view.hoveredAnnotationID, ids[1], "bravo scrolled under the pointer")
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[1], in: harness)), 0.57, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[0], in: harness)), 0.42, accuracy: 0.001)

        // Gone from the view: scrolling hovers nothing.
        pointer(.mouseExited, atWindowPoint: NSPoint(x: -5, y: -5), trackedBy: view)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y - shift))
        scrollView.reflectScrolledClipView(clip)
        spin(0.05)
        XCTAssertNil(view.hoveredAnnotationID)
    }

    /// Selected and hovered are separate looks that combine; a redraw of the
    /// hovered highlight (here a color change from its context menu) keeps
    /// the hover look.
    @MainActor
    func testHoverCombinesWithSelectionAndSurvivesARedraw() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let alpha = ids[0]
        harness.state.highlightClicked(alpha)
        spin(0.2)
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.72, accuracy: 0.001)
        let point = try harness.windowPoint(ofHighlight: alpha)
        moveMouse(toWindowPoint: point, in: harness.window)
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.88, accuracy: 0.001, "selected and hovered")

        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(harness.pdfView.menu(for: rightClick))
        XCTAssertEqual(menu.items.last?.title, "Delete Highlight and Comments")
        let green = try XCTUnwrap(menu.items.first { $0.title == "Green" })
        _ = green.target?.perform(green.action, with: green)
        spin(0.2)
        let redrawn = try XCTUnwrap(harness.annotations()[alpha]?.first)
        XCTAssertEqual(harness.state.activeHighlights.first { $0.id == alpha }?.color, "green")
        XCTAssertEqual(redrawn.color.alphaComponent, 0.88, accuracy: 0.001, "the redrawn highlight keeps the hover look")

        moveMouse(toWindowPoint: try harness.windowPoint(ofText: "nobody highlighted"), in: harness.window)
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.72, accuracy: 0.001, "selected, no longer hovered")
    }

    // MARK: Old behaviour with real events

    /// The owner's must-keep, with real events: a click on a highlight
    /// (posted to the app's queue and dispatched by NSApp, as in the app)
    /// selects it and leaves the keyboard in the PDF, and ⌫ through the
    /// window deletes it with its comment. With no pointer event after the
    /// delete, the hover is dropped everywhere and the hand gives way to the
    /// I-beam over the text that was under the highlight; ⌘Z brings back the
    /// highlight, hovered again in every place, since the pointer is on it.
    @MainActor
    func testRealClickThenDeleteKeyRemovesAHoveredHighlight() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let state = harness.state
        let alpha = ids[0]
        state.selectHighlight(try XCTUnwrap(state.activeHighlights.first { $0.id == alpha }), navigate: false)
        state.commentDraft = "Linked"
        state.saveCommentFromKeyboard()
        state.clearEntrySelection()
        spin(0.2)
        harness.window.makeFirstResponder(harness.pdfView)

        let point = try harness.windowPoint(ofHighlight: alpha)
        moveMouse(toWindowPoint: point, in: harness.window)
        harness.window.makeFirstResponder(nil)
        let hit = try XCTUnwrap(hitView(atWindowPoint: point, in: harness.window))
        XCTAssertTrue(sequence(first: hit, next: \.superview).contains { $0 === harness.pdfView }, "the click goes to the PDF")
        withFirstMouseAccepted(by: [type(of: hit)]) {
            dispatchThroughQueue([
                mouseEvent(.leftMouseDown, at: point, in: harness.window),
                mouseEvent(.leftMouseUp, at: point, in: harness.window),
            ])
        }
        spin(0.2)
        XCTAssertEqual(state.selectedHighlightID, alpha, "the click selected the highlight")
        XCTAssertTrue(harness.window.firstResponder === harness.pdfView, "the keyboard is in the PDF")
        XCTAssertNil(state.currentSelection, "a click is not a text selection")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.88, accuracy: 0.001, "selected and still hovered")

        harness.window.sendEvent(keyDown(51, characters: "\u{7f}", in: harness.window))
        spin(0.2)
        XCTAssertFalse(state.activeHighlights.contains { $0.id == alpha }, "⌫ deleted it")
        XCTAssertTrue(state.activeComments.isEmpty, "with its comment")
        XCTAssertNil(harness.pdfView.hoveredAnnotationID)
        XCTAssertNil(state.annotationHover.pageHoveredID)
        XCTAssertFalse(state.annotationHover.flag(for: alpha).isHoveredOnPage)
        XCTAssertEqual(cursorName(NSCursor.current), "I-beam", "no hand left over the deleted highlight")

        state.performUndo()
        spin(0.2)
        XCTAssertTrue(state.activeHighlights.contains { $0.id == alpha })
        XCTAssertNotNil(harness.annotations()[alpha], "redrawn after undo")
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, alpha, "the pointer is on it again")
        XCTAssertEqual(state.annotationHover.pageHoveredID, alpha)
        XCTAssertTrue(state.annotationHover.flag(for: alpha).isHoveredOnPage, "its card lit, matching the page")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: alpha, in: harness)), 0.57, accuracy: 0.001, "hovered again (undo does not reselect)")
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")
    }

    /// Text selection by dragging works as before, on plain text and from
    /// inside a highlight under the pointer, and a drag is never a click.
    @MainActor
    func testRealDragSelectsTextAsBefore() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let state = harness.state
        let page = try XCTUnwrap(harness.pdfView.document?.page(at: 0))

        func dragAcross(_ text: String) throws {
            let match = try XCTUnwrap(harness.pdfView.document?.findString(text, withOptions: .caseInsensitive).first)
            let bounds = match.bounds(for: page)
            let start = harness.windowPoint(NSPoint(x: bounds.minX + 1, y: bounds.midY), on: page)
            let end = harness.windowPoint(NSPoint(x: bounds.maxX - 1, y: bounds.midY), on: page)
            harness.window.makeFirstResponder(harness.pdfView)
            moveMouse(toWindowPoint: start, in: harness.window)
            let hit = try XCTUnwrap(hitView(atWindowPoint: start, in: harness.window))
            XCTAssertTrue(sequence(first: hit, next: \.superview).contains { $0 === harness.pdfView }, "the drag goes to the PDF")
            withFirstMouseAccepted(by: [type(of: hit)]) {
                drag(from: start, to: end, in: harness.window)
            }
        }

        try dragAcross("Selectable sentence for the drag")
        XCTAssertEqual(state.currentSelection?.selectedText.trimmingCharacters(in: .whitespaces).hasPrefix("Selectable sentence"), true,
                       "dragging selected the text: \(String(describing: state.currentSelection?.selectedText))")
        XCTAssertNil(state.selectedHighlightID)
        XCTAssertEqual(state.activeHighlights.count, 2, "no highlight made")

        harness.pdfView.clearSelection()
        try dragAcross("Bravo passage")
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, ids[1], "the drag began with the pointer on a highlight")
        XCTAssertEqual(state.currentSelection?.selectedText.contains("ravo passag"), true,
                       "a drag that starts on a highlight selects its text: \(String(describing: state.currentSelection?.selectedText))")
        XCTAssertNil(state.selectedHighlightID, "and does not click the highlight")
    }

    /// A selection drag that starts on a highlight and ends on plain text:
    /// PDFKit tracks the drag itself, so no mouse-moved event follows, yet
    /// the hover must follow the pointer off the highlight, and the cursor
    /// must be the I-beam, not the hand.
    @MainActor
    func testDragFromAHighlightToPlainTextLeavesNoHover() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let state = harness.state
        let alpha = try XCTUnwrap(harness.annotations()[ids[0]]?.first)
        let page = try XCTUnwrap(alpha.page)
        let start = harness.windowPoint(NSPoint(x: alpha.bounds.minX + 2, y: alpha.bounds.midY), on: page)
        let end = try harness.windowPoint(ofText: "nobody highlighted")
        moveMouse(toWindowPoint: start, in: harness.window)
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, ids[0])
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")

        let hit = try XCTUnwrap(hitView(atWindowPoint: start, in: harness.window))
        withFirstMouseAccepted(by: [type(of: hit)]) {
            drag(from: start, to: end, in: harness.window)
        }
        spin(0.1)
        XCTAssertEqual(state.currentSelection?.selectedText.contains("Plain words that nobody"), true,
                       "the drag selected text: \(String(describing: state.currentSelection?.selectedText))")
        XCTAssertNil(harness.pdfView.hoveredAnnotationID, "the pointer left the highlight")
        XCTAssertNil(state.annotationHover.pageHoveredID)
        XCTAssertFalse(state.annotationHover.flag(for: ids[0]).isHoveredOnPage, "its card is not lit")
        XCTAssertEqual(try XCTUnwrap(self.alpha(of: ids[0], in: harness)), 0.42, accuracy: 0.001)
        XCTAssertEqual(cursorName(NSCursor.current), "I-beam")

        // Scrolling now hit-tests where the pointer is, not where the drag began.
        let scrollView = try XCTUnwrap(harness.pdfView.subviews.lazy.compactMap { $0 as? NSScrollView }.first)
        scrollView.contentView.scroll(to: scrollView.contentView.bounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        spin(0.05)
        XCTAssertNil(harness.pdfView.hoveredAnnotationID)
    }

    /// A new document opens at its saved page under a still pointer: the
    /// scroll to that page finds a highlight under the pointer in the same
    /// update that reset the hover for the new document. The view, the shared
    /// hover object, the card and the page must end up agreeing.
    @MainActor
    func testNewDocumentRestoredUnderAStillPointerIsHoveredEverywhere() throws {
        let (harness, _) = try reader(highlighting: ["Alpha passage"])
        defer { harness.close(self) }
        let state = harness.state
        let view = harness.pdfView

        // Where "Golf passage" sits once page 2 is scrolled to.
        let secondPage = try XCTUnwrap(view.document?.page(at: 1))
        view.go(to: secondPage)
        spin(0.1)
        let pointer = try harness.windowPoint(ofText: "Golf passage")
        view.go(to: try XCTUnwrap(view.document?.page(at: 0)))
        spin(0.1)
        moveMouse(toWindowPoint: pointer, in: harness.window)
        XCTAssertNil(view.hoveredAnnotationID, "nothing under the pointer at the top of the first paper")

        // The same paper again as a new document, with a highlight on Golf,
        // reopened at page 2, all in one update, as loading a session does.
        let document = TestPDF.make(pages: Self.pages, size: NSSize(width: 500, height: 420))
        let page = try XCTUnwrap(document.page(at: 1))
        let golf = try XCTUnwrap(document.findString("Golf passage", withOptions: .caseInsensitive).first)
        let rect = golf.bounds(for: page)
        let record = HighlightRecord(
            quote: "Golf passage", prefix: "", suffix: "",
            locations: [HighlightLocation(
                pageIndex: 1, pageLabel: "2",
                lineRects: [RectRecord(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)],
                textRanges: [TextRangeRecord(location: 0, length: 12)])],
            color: "green")
        state.document = document
        state.highlights = [record]
        state.comments = []
        state.navigationPageIndex = 1
        state.navigationHighlightID = nil
        state.navigationRequestID = UUID()
        spin(0.3)

        XCTAssertEqual(view.hoveredAnnotationID, record.id, "the pointer is on Golf after the restore")
        XCTAssertEqual(state.annotationHover.pageHoveredID, record.id, "the shared hover agrees")
        XCTAssertTrue(state.annotationHover.flag(for: record.id).isHoveredOnPage, "the card is lit")
        XCTAssertEqual(try XCTUnwrap(alpha(of: record.id, in: harness)), 0.57, accuracy: 0.001, "the page highlight is lit")

        // Moving within it changes nothing, and off it clears all of them.
        var along = pointer
        along.x += 8
        moveMouse(toWindowPoint: along, in: harness.window)
        XCTAssertEqual(state.annotationHover.pageHoveredID, record.id)
        moveMouse(toWindowPoint: try harness.windowPoint(ofText: "Hotel passage"), in: harness.window)
        spin(0.05)
        XCTAssertNil(state.annotationHover.pageHoveredID)
        XCTAssertFalse(state.annotationHover.flag(for: record.id).isHoveredOnPage)
        XCTAssertEqual(try XCTUnwrap(alpha(of: record.id, in: harness)), 0.42, accuracy: 0.001)
    }

    /// A hovered card's highlight is deleted and restored by ⌘Z before the
    /// card's leave delay has run out; the pointer is back on the card. The
    /// restored highlight must be lit on the page, as the card is hovered.
    @MainActor
    func testRestoredHighlightOfAHoveredCardIsLit() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let state = harness.state
        let hover = state.annotationHover
        let bravo = ids[1]
        hover.cardHoverChanged(bravo, isHovering: true)
        spin(AnnotationHover.cardHoverDelay + 0.2)
        XCTAssertEqual(try XCTUnwrap(alpha(of: bravo, in: harness)), 0.57, accuracy: 0.001)

        state.deleteHighlight(bravo)
        spin(0.03)
        XCTAssertNil(harness.annotations()[bravo])
        hover.cardHoverChanged(bravo, isHovering: false)   // the card went away under the pointer
        state.performUndo()
        spin(0.03)
        hover.cardHoverChanged(bravo, isHovering: true)    // and is back under it
        spin(AnnotationHover.cardHoverDelay + 0.2)
        XCTAssertEqual(hover.cardHoveredID, bravo)
        XCTAssertEqual(try XCTUnwrap(alpha(of: bravo, in: harness)), 0.57, accuracy: 0.001, "the restored highlight is lit")
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[0], in: harness)), 0.42, accuracy: 0.001)
    }

    // MARK: Linked hover (item 2)

    @MainActor
    private func sidebarBitmap(_ harness: ReaderHarness) throws -> NSBitmapImageRep {
        let sidebar = NSRect(x: ReaderHarness.pdfWidth, y: 0,
                             width: harness.host.bounds.width - ReaderHarness.pdfWidth, height: harness.host.bounds.height)
        let rep = try XCTUnwrap(harness.host.bitmapImageRepForCachingDisplay(in: sidebar))
        harness.host.cacheDisplay(in: sidebar, to: rep)
        return rep
    }

    /// The rows, in points from the top, where two renders differ.
    private func changedRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> ClosedRange<Int>? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let pa = a.bitmapData, let pb = b.bitmapData else { return nil }
        let scale = Double(a.pixelsHigh) / Double(a.size.height)
        var first: Int?, last: Int?
        for y in 0..<a.pixelsHigh {
            let row = y * a.bytesPerRow
            for x in 0..<(a.pixelsWide * a.samplesPerPixel) where abs(Int(pa[row + x]) - Int(pb[row + x])) > 1 {
                first = first ?? y
                last = y
                break
            }
        }
        guard let first, let last else { return nil }
        return Int(Double(first) / scale)...Int(Double(last) / scale)
    }

    /// Hovering a highlight on the page gives its card, and only its card, the
    /// hover look; leaving restores the list exactly. Checked on the rendered
    /// sidebar, so it covers the real card view observing the real flag.
    @MainActor
    func testPageHoverLightsOnlyThatCard() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage", "Charlie passage"])
        defer { harness.close(self) }
        spin(0.3)
        let before = try sidebarBitmap(harness)

        moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: ids[0]), in: harness.window, settle: 0.4)
        let onAlpha = try sidebarBitmap(harness)
        let alphaRows = try XCTUnwrap(changedRows(before, onAlpha), "page hover changed nothing in the sidebar")
        XCTAssertLessThan(alphaRows.count, 70, "one card changed, not the list: rows \(alphaRows)")

        moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: ids[2]), in: harness.window, settle: 0.4)
        let onCharlie = try sidebarBitmap(harness)
        let charlieRows = try XCTUnwrap(changedRows(before, onCharlie))
        XCTAssertLessThan(charlieRows.count, 70, "rows \(charlieRows)")
        XCTAssertGreaterThan(charlieRows.lowerBound, alphaRows.upperBound, "charlie's card is further down the list than alpha's")

        moveMouse(toWindowPoint: try harness.windowPoint(ofText: "nobody highlighted"), in: harness.window, settle: 0.4)
        XCTAssertNil(changedRows(before, try sidebarBitmap(harness)), "leaving the highlight restores the list")
    }

    /// Hovering a card lights its highlight on the page after a short rest,
    /// without scrolling. Passing quickly over several cards, as when the
    /// list scrolls under a still pointer, lights only where the pointer
    /// stops, and the page is restyled once.
    @MainActor
    func testCardHoverLightsThePageAfterARest() throws {
        final class Recorder: AnnotationHoverObserver {
            weak var next: AnnotationHoverObserver?
            var calls = 0
            func cardHoverDidChange() { calls += 1; next?.cardHoverDidChange() }
        }
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage", "Charlie passage", "Delta passage"])
        defer { harness.close(self) }
        let hover = harness.state.annotationHover
        let recorder = Recorder()
        recorder.next = hover.cardHoverObserver
        XCTAssertNotNil(recorder.next, "the PDF reader observes card hover")
        hover.cardHoverObserver = recorder
        let baseline = markEveryAnnotation(harness)
        let scrolled = harness.pdfView.documentView?.visibleRect

        for id in ids.prefix(3) {
            hover.cardHoverChanged(id, isHovering: true)
            spin(0.02)
            hover.cardHoverChanged(id, isHovering: false)
        }
        hover.cardHoverChanged(ids[3], isHovering: true)
        XCTAssertEqual(drawn(harness), baseline, "nothing lit while the pointer is still passing")
        spin(AnnotationHover.cardHoverDelay + 0.2)
        XCTAssertEqual(recorder.calls, 1, "one change, where the pointer stopped")
        XCTAssertEqual(hover.cardHoveredID, ids[3])
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[3], in: harness)), 0.57, accuracy: 0.001)
        for id in ids.prefix(3) { XCTAssertEqual(drawn(harness)[id], baseline[id]) }
        XCTAssertFalse(hover.flag(for: ids[3]).isHoveredOnPage, "the card's own hover is not a page hover")
        XCTAssertEqual(harness.pdfView.documentView?.visibleRect, scrolled, "the page did not scroll")

        // Leaving the card: the highlight goes back after the same rest.
        hover.cardHoverChanged(ids[3], isHovering: false)
        spin(AnnotationHover.cardHoverDelay + 0.2)
        XCTAssertNil(hover.cardHoveredID)
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[3], in: harness)), 0.42, accuracy: 0.001)
        for id in ids.prefix(3) { XCTAssertEqual(drawn(harness)[id], baseline[id], "never restyled") }
        XCTAssertEqual(recorder.calls, 2)
    }

    /// The card's own hover handler is what reports to the page: the pointer
    /// entering and moving over a card, delivered to the tracking area SwiftUI
    /// keeps for hover, lights that card's highlight; leaving puts it back.
    @MainActor
    func testRealPointerOnACardLightsItsHighlight() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let texts = try harness.cardTextFrames(self)
        XCTAssertEqual(texts.count, 2, "one text per card: \(texts)")
        guard texts.count == 2 else { return }
        let onBravo = NSPoint(x: texts[1].midX, y: texts[1].midY)
        let owner = try harness.hoverTracker(at: onBravo, self)
        XCTAssertTrue(String(describing: type(of: owner)).hasPrefix("NSHostingView"), "\(type(of: owner))")
        let baseline = markEveryAnnotation(harness)

        pointer(.mouseEntered, atWindowPoint: onBravo, trackedBy: owner)
        pointer(.mouseMoved, atWindowPoint: onBravo, trackedBy: owner)
        XCTAssertEqual(drawn(harness), baseline, "not before the rest")
        spin(AnnotationHover.cardHoverDelay + 0.3)
        XCTAssertEqual(harness.state.annotationHover.cardHoveredID, ids[1], "the pointer on bravo's card lights bravo")
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[1], in: harness)), 0.57, accuracy: 0.001)
        XCTAssertEqual(drawn(harness)[ids[0]], baseline[ids[0]], "alpha untouched")

        pointer(.mouseExited, atWindowPoint: onBravo, trackedBy: owner)
        spin(AnnotationHover.cardHoverDelay + 0.3)
        XCTAssertNil(harness.state.annotationHover.cardHoveredID)
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[1], in: harness)), 0.42, accuracy: 0.001, "leaving the card puts the page back")
        XCTAssertEqual(drawn(harness)[ids[0]], baseline[ids[0]], "alpha never restyled")
    }

    /// The pointer entering and leaving the PDF view through its own hover
    /// tracking area, as AppKit delivers those.
    @MainActor
    func testPointerLeavingThePDFViewDropsTheHover() throws {
        let (harness, ids) = try reader(highlighting: ["Alpha passage", "Bravo passage"])
        defer { harness.close(self) }
        let view = harness.pdfView
        let onAlpha = try harness.windowPoint(ofHighlight: ids[0])
        pointer(.mouseEntered, atWindowPoint: onAlpha, trackedBy: view)
        XCTAssertEqual(view.hoveredAnnotationID, ids[0], "entering on a highlight hovers it")
        pointer(.mouseMoved, atWindowPoint: try harness.windowPoint(ofHighlight: ids[1]), trackedBy: view)
        XCTAssertEqual(view.hoveredAnnotationID, ids[1])
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[1], in: harness)), 0.57, accuracy: 0.001)
        pointer(.mouseExited, atWindowPoint: NSPoint(x: -5, y: -5), trackedBy: view)
        XCTAssertNil(view.hoveredAnnotationID)
        XCTAssertNil(harness.state.annotationHover.pageHoveredID)
        XCTAssertEqual(try XCTUnwrap(alpha(of: ids[1], in: harness)), 0.42, accuracy: 0.001)
    }

    // MARK: The hover object

    @MainActor
    func testCardHoverIgnoresALateExitFromThePreviousCard() {
        let hover = AnnotationHover()
        let a = UUID(), b = UUID()
        // SwiftUI may report entering the next card before leaving the last.
        hover.cardHoverChanged(b, isHovering: true)
        hover.cardHoverChanged(a, isHovering: false)
        spin(AnnotationHover.cardHoverDelay + 0.15)
        XCTAssertEqual(hover.cardHoveredID, b)

        hover.setPageHovered(a)
        spin(0.02)
        XCTAssertTrue(hover.flag(for: a).isHoveredOnPage)
        hover.setPageHovered(b)
        spin(0.02)
        XCTAssertFalse(hover.flag(for: a).isHoveredOnPage)
        XCTAssertTrue(hover.flag(for: b).isHoveredOnPage)
        hover.reset()
        XCTAssertNil(hover.cardHoveredID)
        XCTAssertNil(hover.pageHoveredID, "the reset itself is immediate")
        spin(0.02)
        XCTAssertFalse(hover.flag(for: b).isHoveredOnPage)

        // The flags publish what is current when they publish: a reset
        // followed at once by a newer hover leaves that hover lit.
        hover.setPageHovered(a)
        hover.reset()
        hover.setPageHovered(b)
        spin(0.02)
        XCTAssertFalse(hover.flag(for: a).isHoveredOnPage)
        XCTAssertTrue(hover.flag(for: b).isHoveredOnPage)
    }
}
