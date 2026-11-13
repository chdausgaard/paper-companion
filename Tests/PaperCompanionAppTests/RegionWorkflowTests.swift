import AppKit
import PDFKit
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// The region tool and saved regions in the real reader, driven by real
/// mouse and key events delivered in-process (see `TestSupport.swift`), in a
/// real reading session in a temporary folder.
final class RegionWorkflowTests: XCTestCase {
    private var sessions: [RegionTestSession] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for session in sessions { session.remove() }
            sessions = []
        }
        super.tearDown()
    }

    @MainActor
    private func reader() throws -> (ReaderHarness, RegionTestSession, PDFPage) {
        let session = try RegionTestSession()
        sessions.append(session)
        let harness = try ReaderHarness(test: self, state: session.state)
        let page = try XCTUnwrap(harness.pdfView.document?.page(at: 0))
        harness.window.makeFirstResponder(harness.pdfView)
        return (harness, session, page)
    }

    private func cursorName(_ cursor: NSCursor) -> String {
        switch cursor {
        case NSCursor.pointingHand: return "pointing hand"
        case NSCursor.iBeam: return "I-beam"
        case NSCursor.arrow: return "arrow"
        case NSCursor.crosshair: return "crosshair"
        default: return "other (\(cursor))"
        }
    }

    /// A press, drag and release through the app's event queue, as in the app.
    @MainActor
    private func realDrag(from start: NSPoint, to end: NSPoint, in harness: ReaderHarness) throws {
        let hit = try XCTUnwrap(hitView(atWindowPoint: start, in: harness.window))
        XCTAssertTrue(sequence(first: hit, next: \.superview).contains { $0 === harness.pdfView }, "the press goes to the PDF")
        withFirstMouseAccepted(by: [type(of: hit)]) {
            drag(from: start, to: end, in: harness.window)
        }
        spin(0.2)
    }

    @MainActor
    private func realClick(at point: NSPoint, in harness: ReaderHarness) throws {
        let hit = try XCTUnwrap(hitView(atWindowPoint: point, in: harness.window))
        withFirstMouseAccepted(by: [type(of: hit)]) {
            dispatchThroughQueue([
                mouseEvent(.leftMouseDown, at: point, in: harness.window),
                mouseEvent(.leftMouseUp, at: point, in: harness.window),
            ])
        }
        spin(0.2)
    }

    @MainActor
    private func pressEscape(in harness: ReaderHarness) {
        // Through the app's queue, so the local key monitors see it as they
        // see the user's key presses.
        dispatchThroughQueue([keyDown(53, characters: "\u{1b}", in: harness.window)])
        spin(0.2)
    }

    private func assertRect(_ rect: CGRect?, equals expected: CGRect, accuracy: CGFloat = 1, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else { return XCTFail("no rect \(message)", file: file, line: line) }
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.maxX, expected.maxX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.maxY, expected.maxY, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: Drawing a region

    /// The whole gesture with real events: the tool on, the crosshair over
    /// the page, a drag across the figure. One region is saved with the
    /// dragged rectangle on the right page, both pictures are on disk, the
    /// record is in `highlights.json`, the tool is off, no text was selected
    /// or highlighted, and the comment box has the keyboard so ⌘↩ saves a
    /// comment linked to the region.
    @MainActor
    func testRealDragDrawsARegionAndTurnsTheToolOff() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state

        state.regionToolActive = true
        spin(0.1)
        XCTAssertTrue(harness.pdfView.isRegionToolActive)
        let figure = FigurePDF.figure
        let start = harness.windowPoint(NSPoint(x: figure.minX, y: figure.maxY), on: page)
        let end = harness.windowPoint(NSPoint(x: figure.maxX, y: figure.minY), on: page)
        moveMouse(toWindowPoint: start, in: harness.window)
        XCTAssertEqual(cursorName(NSCursor.current), "crosshair", "the crosshair over the page")

        try realDrag(from: start, to: end, in: harness)

        let regions = state.activeHighlights.filter(\.isRegion)
        XCTAssertEqual(regions.count, 1, "one region")
        XCTAssertEqual(state.activeHighlights.count, 1, "and no text highlight")
        let region = try XCTUnwrap(regions.first)
        XCTAssertEqual(region.pageIndex, 0)
        XCTAssertEqual(region.pageLabel, "1")
        XCTAssertEqual(region.quote, "", "a region has no quote")
        assertRect(region.regionRect, equals: figure, "the dragged rectangle, in page space")
        XCTAssertFalse(state.regionToolActive, "one-shot: the tool is off")
        XCTAssertFalse(harness.pdfView.isRegionToolActive)
        XCTAssertNil(harness.pdfView.regionDrag)
        XCTAssertFalse(harness.pdfView.subviews.contains { $0 is RegionDragOverlay }, "the live box is gone")
        XCTAssertNil(state.currentSelection, "the drag selected no text")
        XCTAssertEqual(state.selectedHighlightID, region.id, "the new region is selected")
        XCTAssertEqual(state.inspectorTab, .annotations)

        // What the agent gets.
        XCTAssertTrue(region.region?.textInRegion.contains("2013") ?? false, "the year labels are text inside the box")
        XCTAssertTrue(region.region?.captionGuess?.lowercased().contains("figure 2") ?? false,
                      "caption guess: \(String(describing: region.region?.captionGuess))")
        XCTAssertNotNil(session.paths.regionImage(of: region), "regions/<id>.png written")
        XCTAssertNotNil(session.paths.regionPageImage(of: region), "regions/<id>-page.png written")
        let saved = try SessionRepository().loadSession(at: session.paths.root)
        XCTAssertEqual(saved.highlights.map(\.id), [region.id])
        XCTAssertEqual(saved.highlights.first?.kind, .region, "saved as a region")
        let context = try String(contentsOf: session.paths.currentContextJSON, encoding: .utf8)
        XCTAssertTrue(context.contains("\"textStatus\" : \"region\""), context)
        XCTAssertTrue(context.contains("activeRegion"), "the active anchor is the region")

        // On the page: one outline, where the box was drawn.
        let drawn = try XCTUnwrap(harness.annotations()[region.id])
        XCTAssertEqual(drawn.count, 1)
        XCTAssertTrue(drawn.first is RegionAnnotation)
        assertRect(drawn.first?.bounds, equals: figure)

        // The cursor is in the comment box; ⌘↩ links the comment.
        spin(0.4)
        XCTAssertTrue(harness.window.firstResponder is CommentTextView,
                      "the comment box has the keyboard: \(String(describing: harness.window.firstResponder))")
        state.commentDraft = "Is the 2015 bar the reform year?"
        state.saveCommentFromKeyboard()
        XCTAssertEqual(state.activeComments.first?.highlightID, region.id, "linked to the region")
        XCTAssertEqual(state.statusMessage, "Comment linked to the region · visible under Saved comments")
    }

    /// A slip of the mouse is not a region, and the tool still ends: one
    /// press, one use.
    @MainActor
    func testTooSmallDragCancels() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        state.regionToolActive = true
        spin(0.1)
        let start = harness.windowPoint(NSPoint(x: 100, y: 200), on: page)
        try realDrag(from: start, to: NSPoint(x: start.x + 5, y: start.y - 4), in: harness)

        XCTAssertTrue(state.highlights.isEmpty, "nothing saved")
        XCTAssertFalse(state.regionToolActive)
        XCTAssertFalse(harness.pdfView.isRegionToolActive)
        XCTAssertTrue(state.statusMessage.contains("too small"), state.statusMessage)
        XCTAssertNil(state.currentSelection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.paths.regions.path), "no pictures written")
    }

    /// Esc while the tool is on turns it off and does nothing else: a box
    /// half drawn is dropped, the rest of that press selects no text, and
    /// the expanded card stays expanded. Only the next Esc collapses it.
    @MainActor
    func testEscapeEndsTheToolBeforeItCollapsesACard() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let plain = try harness.highlight("Plain words under the figure", test: self)
        state.highlightClicked(plain)
        spin(0.3)
        harness.window.makeFirstResponder(harness.pdfView)
        XCTAssertEqual(state.selectedHighlightID, plain, "a card is expanded")

        state.regionToolActive = true
        spin(0.2)
        let a = harness.windowPoint(NSPoint(x: 60, y: 280), on: page)
        let b = harness.windowPoint(NSPoint(x: 200, y: 180), on: page)
        let c = harness.windowPoint(NSPoint(x: 300, y: 140), on: page)
        let hit = try XCTUnwrap(hitView(atWindowPoint: a, in: harness.window))
        withFirstMouseAccepted(by: [type(of: hit)]) {
            harness.window.sendEvent(mouseEvent(.leftMouseDown, at: a, in: harness.window))
            harness.window.sendEvent(mouseEvent(.leftMouseDragged, at: b, in: harness.window))
        }
        spin(0.05)
        XCTAssertNotNil(harness.pdfView.regionDrag, "a box is being drawn")
        XCTAssertTrue(harness.pdfView.subviews.contains { $0 is RegionDragOverlay })

        pressEscape(in: harness)
        XCTAssertFalse(state.regionToolActive, "Esc turned the tool off")
        XCTAssertFalse(harness.pdfView.isRegionToolActive)
        XCTAssertNil(harness.pdfView.regionDrag, "the half-drawn box is dropped")
        XCTAssertFalse(harness.pdfView.subviews.contains { $0 is RegionDragOverlay })
        XCTAssertEqual(state.selectedHighlightID, plain, "and did not collapse the card")

        // The rest of the press: no box, no text selection.
        harness.window.sendEvent(mouseEvent(.leftMouseDragged, at: c, in: harness.window))
        harness.window.sendEvent(mouseEvent(.leftMouseUp, at: c, in: harness.window))
        spin(0.2)
        XCTAssertFalse(state.highlights.contains(where: \.isRegion), "no region")
        XCTAssertNil(state.currentSelection, "no text selected by the rest of the press")
        XCTAssertNil(harness.pdfView.currentSelection?.string)

        pressEscape(in: harness)
        XCTAssertNil(state.selectedHighlightID, "now Esc collapses the card")
    }

    /// Esc in the comment box while the tool is on is the tool's too: the
    /// box keeps the keyboard (an empty box would otherwise hand it to the
    /// PDF).
    @MainActor
    func testEscapeInTheCommentBoxOnlyEndsTheTool() throws {
        let (harness, session, _) = try reader()
        defer { harness.close(self) }
        let state = session.state
        // The harness's borderless window cannot be key, and the app hands
        // key presses on only to a window that can: move the reader into one
        // that can, so a key press that gets past the monitors reaches the
        // comment box as it would in the app. (The test process is never the
        // active app, so the window does not report itself key; the second
        // press below shows the route works.)
        let keyWindow = KeyableTestWindow(contentRect: harness.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        keyWindow.isReleasedWhenClosed = false
        keyWindow.contentView = harness.host
        keyWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        keyWindow.orderFrontRegardless()
        keyWindow.makeKey()
        defer { closeOffscreenWindow(keyWindow) }
        spin(0.2)
        let box = try XCTUnwrap(descendants(of: harness.host, as: CommentTextView.self).first)
        keyWindow.makeFirstResponder(box)
        state.regionToolActive = true
        spin(0.2)
        dispatchThroughQueue([keyDown(53, characters: "\u{1b}", in: keyWindow)])
        spin(0.2)
        XCTAssertFalse(state.regionToolActive)
        XCTAssertTrue(keyWindow.firstResponder === box, "the comment box still has the keyboard")
        XCTAssertEqual(state.statusMessage, "Comment on Region cancelled")
        // The same key with the tool off reaches the empty box, which hands
        // the keyboard to the PDF: the route the first press was kept from.
        dispatchThroughQueue([keyDown(53, characters: "\u{1b}", in: keyWindow)])
        spin(0.3)
        XCTAssertTrue(keyWindow.firstResponder === harness.pdfView, "with the tool off, Esc reaches the box as before")
    }

    // MARK: A saved region on the page

    /// A real click inside a region selects it and leaves the keyboard in
    /// the PDF; ⌫ removes it and its comment and drops the hover under the
    /// still pointer; Undo (what ⌘Z calls) restores both and the pointer is
    /// on it again; Redo removes it again. The pictures stay on disk.
    @MainActor
    func testClickSelectsDeleteKeyRemovesAndUndoRestores() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        state.commentDraft = "Which bar is the reform year?"
        state.saveCommentFromKeyboard()
        XCTAssertEqual(state.activeComments.first?.highlightID, region.id)
        state.clearEntrySelection()
        spin(0.4)
        harness.window.makeFirstResponder(harness.pdfView)

        // Blank chart area inside the box, clear of the bars and labels.
        let point = harness.windowPoint(NSPoint(x: FigurePDF.figure.minX + 6, y: FigurePDF.figure.maxY - 6), on: page)
        moveMouse(toWindowPoint: point, in: harness.window)
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, region.id, "hover finds the region")
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")
        XCTAssertEqual(state.annotationHover.pageHoveredID, region.id)

        harness.window.makeFirstResponder(nil)
        try realClick(at: point, in: harness)
        XCTAssertEqual(state.selectedHighlightID, region.id, "the click selected the region")
        XCTAssertTrue(harness.window.firstResponder === harness.pdfView, "the keyboard is in the PDF")
        XCTAssertNil(state.currentSelection)
        let selectedLook = try XCTUnwrap(harness.annotations()[region.id]?.first)
        XCTAssertEqual(selectedLook.color.alphaComponent, 1, accuracy: 0.001, "selected and hovered: the firmest outline")

        harness.window.sendEvent(keyDown(51, characters: "\u{7f}", in: harness.window))
        spin(0.2)
        XCTAssertFalse(state.activeHighlights.contains { $0.id == region.id }, "⌫ removed the region")
        XCTAssertTrue(state.activeComments.isEmpty, "and its comment")
        XCTAssertNil(harness.annotations()[region.id], "its outline is gone")
        XCTAssertNil(harness.pdfView.hoveredAnnotationID, "no hover left on a deleted region")
        XCTAssertNil(state.annotationHover.pageHoveredID)
        XCTAssertFalse(state.annotationHover.flag(for: region.id).isHoveredOnPage)
        XCTAssertNotEqual(cursorName(NSCursor.current), "pointing hand", "no hand over the empty spot")
        XCTAssertEqual(state.statusMessage, "Region and linked comments removed · ⌘Z to undo")
        XCTAssertNotNil(session.paths.regionImage(of: region), "the pictures stay for an undo")

        state.performUndo()
        spin(0.2)
        XCTAssertTrue(state.activeHighlights.contains { $0.id == region.id }, "⌘Z restored it")
        XCTAssertEqual(state.activeComments.first?.highlightID, region.id, "with its comment")
        XCTAssertTrue(harness.annotations()[region.id]?.first is RegionAnnotation, "drawn again")
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, region.id, "the pointer is on it again")
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")
        XCTAssertEqual(state.statusMessage, "Region restored")

        state.performRedo()
        spin(0.2)
        XCTAssertFalse(state.activeHighlights.contains { $0.id == region.id }, "redo removes it again")
        XCTAssertNil(harness.annotations()[region.id])
        state.performUndo()
        spin(0.2)
        XCTAssertNotNil(harness.annotations()[region.id])
    }

    /// Undo right after drawing removes the new region (action "Region").
    @MainActor
    func testUndoRemovesANewRegion() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        XCTAssertEqual(state.undoManager.undoActionName, "Region")
        XCTAssertNotNil(state.commentFocusRequestID, "drawing a region asks for the comment box")
        state.performUndo()
        spin(0.2)
        XCTAssertFalse(state.activeHighlights.contains { $0.id == region.id })
        XCTAssertNil(state.selectedHighlightID)
        XCTAssertNil(harness.annotations()[region.id])
    }

    /// Where a highlight and a region overlap, the smaller one takes the
    /// click: a highlighted year label inside a boxed chart, and a small box
    /// inside a highlighted line. Real clicks.
    @MainActor
    func testTheSmallerAnnotationWinsTheClick() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let year = try harness.highlight("2013", test: self)
        let chart = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        let line = try harness.highlight("Plain words under the figure for the selection test", test: self)
        let lineBounds = try XCTUnwrap(harness.annotations()[line]?.first?.bounds)
        let small = CGRect(x: lineBounds.midX - 15, y: lineBounds.minY, width: 30, height: max(lineBounds.height, 9))
        let smallRegion = try XCTUnwrap(state.createRegion(on: page, rect: small))
        state.clearEntrySelection()
        spin(0.4)

        func clickSelects(_ point: NSPoint, _ expected: UUID, _ what: String) throws {
            state.clearEntrySelection()
            harness.window.makeFirstResponder(harness.pdfView)
            try realClick(at: point, in: harness)
            XCTAssertEqual(state.selectedHighlightID, expected, what)
        }
        try clickSelects(try harness.windowPoint(ofHighlight: year), year, "the year highlight inside the chart box")
        try clickSelects(harness.windowPoint(NSPoint(x: FigurePDF.figure.minX + 6, y: FigurePDF.figure.maxY - 6), on: page),
                         chart.id, "the chart box away from the highlight")
        try clickSelects(harness.windowPoint(NSPoint(x: small.midX, y: small.midY), on: page),
                         smallRegion.id, "the small box inside the highlighted line")
        try clickSelects(harness.windowPoint(NSPoint(x: lineBounds.minX + 4, y: lineBounds.midY), on: page),
                         line, "the line away from the small box")
    }

    // MARK: Rotated pages and offset crop boxes

    /// The saved outline is drawn where the stored rectangle is on screen,
    /// on pages turned 0, 90, 180 and 270 degrees and on a page whose crop
    /// box does not start at the origin: the same place the live box and the
    /// hit test use (`PDFView.convert(_:from: page)`). Found from the drawn
    /// pixels of the outline in the reader as rendered.
    @MainActor
    func testOutlineSitsOnItsRectangleOnRotatedAndCroppedPages() throws {
        let cases: [(name: String, rotation: Int, crop: CGRect?)] = [
            ("0°", 0, nil), ("90°", 90, nil), ("180°", 180, nil), ("270°", 270, nil),
            ("offset crop box", 0, CGRect(x: 60, y: 40, width: 300, height: 220)),
            ("offset crop box, 90°", 90, CGRect(x: 60, y: 40, width: 300, height: 220)),
        ]
        let rect = CGRect(x: 90, y: 70, width: 120, height: 70)
        for item in cases {
            let state = AppState()
            state.autoHighlightEnabled = false
            let document = TestPDF.make(pages: ["A page of text, set at the top.\n\nA second line."], size: NSSize(width: 400, height: 300))
            let page = try XCTUnwrap(document.page(at: 0))
            page.rotation = item.rotation
            if let crop = item.crop { page.setBounds(crop, for: .cropBox) }
            state.document = document
            let harness = try ReaderHarness(test: self, state: state)
            defer { harness.close(self) }
            let region = try XCTUnwrap(RegionSnapshot.makeRecord(page: page, rect: rect, color: "purple"))
            state.highlights = [region]
            spin(0.5)

            let inView = harness.pdfView.convert(rect, from: page)
            let expected = harness.host.convert(inView, from: harness.pdfView)
            XCTAssertEqual(harness.pdfView.annotationID(at: NSPoint(x: inView.midX, y: inView.midY)), region.id,
                           "\(item.name): the hit test finds it at its rectangle")
            let area = NSRect(x: 0, y: 0, width: ReaderHarness.pdfWidth, height: harness.host.bounds.height)
            let image = try SnapshotOutput.readerBitmap(of: harness.host, pdfView: harness.pdfView,
                                                        appearance: try XCTUnwrap(NSAppearance(named: .aqua)), rect: area)
            let found = try XCTUnwrap(outlineBounds(in: image, area: area, flipped: harness.host.isFlipped), "\(item.name): no outline drawn")
            assertRect(found, equals: expected, accuracy: 2.5, "\(item.name): outline drawn at \(found), rectangle at \(expected)")
        }
    }

    /// The bounding box, in the host's coordinates, of the pixels painted in
    /// the purple outline color (saturated violet: none of the page's black
    /// text, its white, or the grey desk).
    @MainActor
    private func outlineBounds(in image: NSBitmapImageRep, area: NSRect, flipped: Bool) -> NSRect? {
        let scale = CGFloat(image.pixelsWide) / area.width
        // Redrawn into plain 8-bit sRGB, top row first, to read the bytes.
        let width = image.pixelsWide, height = image.pixelsHigh
        guard let source = image.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                guard b > 128, b - g > 64, r - g > 25 else { continue }
                // A bitmap context's memory holds the top row first.
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        let left = CGFloat(minX) / scale, right = CGFloat(maxX + 1) / scale
        let top = CGFloat(minY) / scale, bottom = CGFloat(maxY + 1) / scale
        // Image rows run from the top; the host's y runs down only if flipped.
        return flipped
            ? NSRect(x: area.minX + left, y: area.minY + top, width: right - left, height: bottom - top)
            : NSRect(x: area.minX + left, y: area.maxY - bottom, width: right - left, height: bottom - top)
    }

    // MARK: The tool off: the page as before

    /// With the tool off, text inside a region is selected by dragging as
    /// anywhere else, and the drag is not a click on the region.
    @MainActor
    func testTextInsideARegionIsStillSelectable() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        state.clearEntrySelection()
        spin(0.4)
        harness.window.makeFirstResponder(harness.pdfView)

        let first = try XCTUnwrap(harness.pdfView.document?.findString("2009", withOptions: []).first?.bounds(for: page))
        let last = try XCTUnwrap(harness.pdfView.document?.findString("2015", withOptions: []).first?.bounds(for: page))
        let start = harness.windowPoint(NSPoint(x: first.minX + 1, y: first.midY), on: page)
        let end = harness.windowPoint(NSPoint(x: last.maxX - 1, y: last.midY), on: page)
        moveMouse(toWindowPoint: start, in: harness.window)
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, region.id, "the drag begins on the region")
        try realDrag(from: start, to: end, in: harness)

        let selected = state.currentSelection?.selectedText ?? ""
        XCTAssertTrue(selected.contains("2009") && selected.contains("2011"), "the labels were selected: \(selected)")
        XCTAssertNil(state.selectedHighlightID, "the drag did not click the region")
        XCTAssertEqual(state.activeHighlights.count, 1, "no highlight made")
    }

    /// The context menu on a region offers the colors and "Delete Region and
    /// Comments", and both act on the region.
    @MainActor
    func testContextMenuOnARegion() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        state.clearEntrySelection()
        spin(0.3)
        let location = harness.windowPoint(NSPoint(x: FigurePDF.figure.minX + 6, y: FigurePDF.figure.maxY - 6), on: page)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: harness.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(harness.pdfView.menu(for: event))
        XCTAssertEqual(state.selectedHighlightID, region.id, "the menu selects what it acts on")
        XCTAssertEqual(menu.items.map(\.title), HighlightColor.allCases.map { $0.rawValue.capitalized } + ["", "Delete Region and Comments"])

        let blue = try XCTUnwrap(menu.items.first { $0.title == "Blue" })
        _ = blue.target?.perform(blue.action, with: blue)
        spin(0.2)
        XCTAssertEqual(state.activeHighlights.first { $0.id == region.id }?.color, "blue")
        XCTAssertEqual(harness.annotations()[region.id]?.first?.color,
                       PDFReaderView.Coordinator.regionStyle("blue", selected: true, hovered: false).stroke, "redrawn in blue")

        let delete = try XCTUnwrap(menu.items.last)
        _ = delete.target?.perform(delete.action, with: delete)
        spin(0.2)
        XCTAssertFalse(state.activeHighlights.contains { $0.id == region.id })
    }

    // MARK: Cursor and hover with the tool

    /// While the tool is on, nothing answers the pointer as a highlight does
    /// (no hand, no lit highlight): the crosshair over pages, the arrow off
    /// them and when the pointer leaves the PDF. Turning the tool off under
    /// a still pointer brings the hover and the hand straight back.
    @MainActor
    func testCrosshairWhileOnAndNoStaleCursorAfter() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let note = try harness.highlight("Treated places", test: self)
        spin(0.3)
        harness.window.makeFirstResponder(harness.pdfView)
        let onNote = try harness.windowPoint(ofHighlight: note)
        moveMouse(toWindowPoint: onNote, in: harness.window)
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, note)
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand")

        state.regionToolActive = true
        spin(0.2)
        XCTAssertNil(harness.pdfView.hoveredAnnotationID, "no hover while the tool is on")
        XCTAssertNil(state.annotationHover.pageHoveredID)
        XCTAssertEqual(cursorName(NSCursor.current), "crosshair", "under the still pointer")

        let offPage = harness.windowPoint(NSPoint(x: 250, y: FigurePDF.size.height + 5), on: page)
        XCTAssertNil(harness.pdfView.page(for: harness.pdfView.convert(offPage, from: nil), nearest: false), "the desk above the page")
        moveMouse(toWindowPoint: offPage, in: harness.window)
        XCTAssertEqual(cursorName(NSCursor.current), "arrow", "beside the pages")
        moveMouse(toWindowPoint: onNote, in: harness.window)
        XCTAssertEqual(cursorName(NSCursor.current), "crosshair")
        XCTAssertNil(harness.pdfView.hoveredAnnotationID)

        pointer(.mouseExited, atWindowPoint: NSPoint(x: ReaderHarness.pdfWidth + 40, y: 300), trackedBy: harness.pdfView)
        XCTAssertEqual(cursorName(NSCursor.current), "arrow", "the crosshair stays in the PDF")
        moveMouse(toWindowPoint: onNote, in: harness.window)
        XCTAssertEqual(cursorName(NSCursor.current), "crosshair")

        state.regionToolActive = false
        spin(0.2)
        XCTAssertFalse(harness.pdfView.isRegionToolActive)
        XCTAssertEqual(harness.pdfView.hoveredAnnotationID, note, "hover is back under the still pointer")
        XCTAssertEqual(state.annotationHover.pageHoveredID, note)
        XCTAssertEqual(cursorName(NSCursor.current), "pointing hand", "no crosshair left behind")
    }

    // MARK: Stale state

    /// A new document while a box is half drawn drops the box; the rest of
    /// the press draws nothing. The reader leaving the window turns the tool
    /// off, so it does not come back armed.
    @MainActor
    func testDocumentChangeDropsTheBoxAndLeavingTheWindowEndsTheTool() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        state.regionToolActive = true
        spin(0.1)
        let a = harness.windowPoint(NSPoint(x: 60, y: 280), on: page)
        let b = harness.windowPoint(NSPoint(x: 220, y: 160), on: page)
        let hit = try XCTUnwrap(hitView(atWindowPoint: a, in: harness.window))
        withFirstMouseAccepted(by: [type(of: hit)]) {
            harness.window.sendEvent(mouseEvent(.leftMouseDown, at: a, in: harness.window))
            harness.window.sendEvent(mouseEvent(.leftMouseDragged, at: b, in: harness.window))
        }
        XCTAssertNotNil(harness.pdfView.regionDrag)

        state.document = TestPDF.make(pages: ["Another paper entirely."])
        spin(0.3)
        XCTAssertNil(harness.pdfView.regionDrag, "the box on the old document is dropped")
        XCTAssertFalse(harness.pdfView.subviews.contains { $0 is RegionDragOverlay })
        harness.window.sendEvent(mouseEvent(.leftMouseUp, at: b, in: harness.window))
        spin(0.2)
        XCTAssertTrue(state.highlights.isEmpty, "nothing saved")

        XCTAssertTrue(state.regionToolActive)
        harness.pdfView.removeFromSuperview()
        spin(0.2)
        XCTAssertFalse(state.regionToolActive, "the tool ends when the reader leaves the window")
    }

    /// If the pictures cannot be written, there is no region: no record in
    /// memory or on disk, nothing on the page, nothing selected, and the
    /// user is told why. Real drag.
    @MainActor
    func testNoRegionWithoutItsPictures() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        // A file where the regions folder belongs: the folder cannot be made.
        try Data("not a folder".utf8).write(to: session.paths.regions)

        state.regionToolActive = true
        spin(0.1)
        try realDrag(
            from: harness.windowPoint(NSPoint(x: FigurePDF.figure.minX, y: FigurePDF.figure.maxY), on: page),
            to: harness.windowPoint(NSPoint(x: FigurePDF.figure.maxX, y: FigurePDF.figure.minY), on: page),
            in: harness
        )
        XCTAssertTrue(state.highlights.isEmpty, "no region record")
        XCTAssertNil(state.selectedHighlightID)
        XCTAssertTrue(harness.annotations().isEmpty, "nothing drawn")
        XCTAssertFalse(state.regionToolActive)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("Could not save the region: its pictures for the agent could not be written"), message)
        XCTAssertTrue(message.contains("Nothing was added"), message)
        XCTAssertTrue(try SessionRepository().loadSession(at: session.paths.root).highlights.isEmpty, "nothing on disk")
    }

    /// Once the region is saved it exists: a context file that cannot be
    /// written is reported, and the region stays, in memory and on disk,
    /// with its undo.
    @MainActor
    func testAContextWriteFailureKeepsTheSavedRegion() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let contextFile = session.paths.currentContextJSON
        try? FileManager.default.removeItem(at: contextFile)
        try FileManager.default.createDirectory(at: contextFile, withIntermediateDirectories: true)

        let region = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure), "the region is kept")
        XCTAssertTrue(state.activeHighlights.contains { $0.id == region.id })
        XCTAssertEqual(try SessionRepository().loadSession(at: session.paths.root).highlights.map(\.id), [region.id], "and on disk")
        XCTAssertEqual(state.selectedHighlightID, region.id)
        XCTAssertEqual(state.undoManager.undoActionName, "Region", "⌘Z can remove it")
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertTrue(message.hasPrefix("The region was saved, but the agent’s current context could not be updated"), message)
        spin(0.3)
        XCTAssertNotNil(harness.annotations()[region.id], "drawn on the page")
    }

    /// When the save itself fails (here the journal), the region is taken
    /// out of memory and out of the records on disk, so the two agree.
    @MainActor
    func testAFailedSaveLeavesNoRegionAnywhere() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let journal = session.paths.eventLog
        try? FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)

        XCTAssertNil(state.createRegion(on: page, rect: FigurePDF.figure))
        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertNil(state.selectedHighlightID)
        XCTAssertTrue(try SessionRepository().loadSession(at: session.paths.root).highlights.isEmpty, "nothing on disk either")
        XCTAssertTrue(try XCTUnwrap(state.errorMessage).hasPrefix("Could not save the region"))
        XCTAssertFalse(state.undoManager.canUndo)
    }

    // MARK: Pictures in the sidebar

    /// Pictures load off the main thread at the size asked for, are kept,
    /// and a missing one is remembered rather than looked for again.
    @MainActor
    func testRegionPicturesLoadSmallOnceAndMissingOnesAreNotRetried() async throws {
        let session = try RegionTestSession()
        sessions.append(session)
        let page = try XCTUnwrap(session.document.page(at: 0))
        let region = try XCTUnwrap(RegionSnapshot.makeRecord(page: page, rect: FigurePDF.figure))
        try RegionSnapshot.writeImages(for: region, page: page, paths: session.paths)

        XCTAssertNil(RegionImageCache.cached(for: region, paths: session.paths, maxPixels: 68), "nothing until loaded")
        guard case .image(let image) = await RegionImageCache.load(for: region, paths: session.paths, maxPixels: 68) else {
            return XCTFail("no picture")
        }
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 68, "scaled down to the size shown, not the full crop")
        XCTAssertNotNil(RegionImageCache.cached(for: region, paths: session.paths, maxPixels: 68), "kept")

        let ghost = try XCTUnwrap(RegionSnapshot.makeRecord(page: page, rect: CGRect(x: 360, y: 190, width: 100, height: 90)))
        let before = RegionImageCache.finishedLoads
        guard case .missing = await RegionImageCache.load(for: ghost, paths: session.paths, maxPixels: 68) else {
            return XCTFail("a region without files is missing")
        }
        XCTAssertEqual(RegionImageCache.finishedLoads, before + 1)
        guard case .missing = await RegionImageCache.load(for: ghost, paths: session.paths, maxPixels: 68) else {
            return XCTFail("still missing")
        }
        XCTAssertEqual(RegionImageCache.finishedLoads, before + 1, "not looked for again")
    }

    // MARK: Where the tool can be on

    /// Closing the window ends the tool and its Esc monitor, though the
    /// window keeps its content view.
    @MainActor
    func testClosingTheWindowEndsTheTool() throws {
        let (harness, session, _) = try reader()
        defer { harness.close(self) }
        let state = session.state
        XCTAssertTrue(state.readerOnScreen)
        state.regionToolActive = true
        spin(0.2)
        XCTAssertTrue(harness.pdfView.hasEscapeMonitor)

        harness.window.close()
        spin(0.2)
        XCTAssertNotNil(harness.pdfView.window, "the closed window still holds the reader")
        XCTAssertFalse(state.regionToolActive, "the tool ended")
        XCTAssertFalse(harness.pdfView.isRegionToolActive)
        XCTAssertFalse(harness.pdfView.hasEscapeMonitor, "and its Esc monitor is gone")
        XCTAssertFalse(state.readerOnScreen)
        state.regionToolActive = true
        XCTAssertFalse(state.regionToolActive, "and it cannot be armed again for a closed reader")
    }

    /// The tool can be armed only while a paper is open and the reader is
    /// on screen (not with the library showing in its place), and it ends
    /// when the reader goes away.
    @MainActor
    func testTheToolNeedsTheReaderOnScreen() {
        let state = AppState()
        state.regionToolActive = true
        XCTAssertFalse(state.regionToolActive, "no paper")
        state.document = TestPDF.make(pages: ["A paper."])
        XCTAssertFalse(state.canUseRegionTool, "a paper, but the library is showing")
        state.regionToolActive = true
        XCTAssertFalse(state.regionToolActive)
        state.readerOnScreenChanged(true)
        XCTAssertTrue(state.canUseRegionTool)
        state.regionToolActive = true
        XCTAssertTrue(state.regionToolActive)
        state.readerOnScreenChanged(false)
        XCTAssertFalse(state.regionToolActive, "the reader went away: the tool ends")
    }

    // MARK: The cursor after the tool

    /// The tool ending over unannotated page content gives back PDFKit's
    /// cursor (the I-beam over text, the arrow over blank page) under a
    /// still pointer: after Esc and after a too-small drag.
    @MainActor
    func testTheCursorComesBackAfterEscAndATooSmallDrag() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let text = try harness.windowPoint(ofText: "Plain words under")
        let blank = harness.windowPoint(NSPoint(x: 430, y: 110), on: page)
        XCTAssertNil(harness.pdfView.annotationID(at: harness.pdfView.convert(blank, from: nil)))

        for (point, expected) in [(text, "I-beam"), (blank, "arrow")] {
            // Esc.
            moveMouse(toWindowPoint: point, in: harness.window)
            state.regionToolActive = true
            spin(0.2)
            XCTAssertEqual(cursorName(NSCursor.current), "crosshair")
            pressEscape(in: harness)
            XCTAssertFalse(state.regionToolActive)
            XCTAssertEqual(cursorName(NSCursor.current), expected, "after Esc")

            // A drag too small to keep.
            state.regionToolActive = true
            spin(0.2)
            XCTAssertEqual(cursorName(NSCursor.current), "crosshair")
            try realDrag(from: point, to: NSPoint(x: point.x + 3, y: point.y - 2), in: harness)
            XCTAssertFalse(state.regionToolActive)
            XCTAssertTrue(state.highlights.isEmpty)
            XCTAssertEqual(cursorName(NSCursor.current), expected, "after a too-small drag")
        }
    }

    /// The same box drawn twice selects the first rather than making a
    /// second.
    @MainActor
    func testTheSameBoxTwiceIsOneRegion() throws {
        let (harness, session, page) = try reader()
        defer { harness.close(self) }
        let state = session.state
        let first = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        state.clearEntrySelection()
        let second = try XCTUnwrap(state.createRegion(on: page, rect: FigurePDF.figure))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(state.highlights.count, 1)
        XCTAssertEqual(state.selectedHighlightID, first.id)
        XCTAssertTrue(state.statusMessage.hasPrefix("This box is already a region"), state.statusMessage)
    }
}

/// A borderless window that can become key, for the one test that needs
/// key presses delivered by the app.
final class KeyableTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
