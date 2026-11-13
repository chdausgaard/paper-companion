import AppKit
import CoreImage
import IOSurface
import ObjectiveC
import PDFKit
import SwiftUI
import XCTest
@testable import PaperCompanion
import PaperCompanionCore

/// Event and offscreen-window helpers shared by the interaction and snapshot
/// tests. Everything stays in-process: events go through `NSWindow.sendEvent`
/// or the app's own event queue, never through the window server, so no
/// accessibility or screen-recording permission is involved.
extension XCTestCase {
    @MainActor
    func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + descendants(of: $0, as: type) }
    }

    /// A window holding `view` that is ordered in, because an unordered window
    /// drops mouse events, but far off every screen, so nothing appears.
    @MainActor
    func offscreenWindow(for view: NSView, styleMask: NSWindow.StyleMask = [.borderless]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        XCTAssertLessThan(window.frame.maxX, 0, "the test window stays off screen")
        view.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    func closeOffscreenWindow(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Runs `body` with the given view classes accepting the first click. The
    /// test process is never the active app, so AppKit treats each click as
    /// one that would activate the app and hands it on only to a view that
    /// accepts first mouse, which SwiftUI's internal views decline. In the app
    /// the user clicks a window of the active app and that question is never
    /// asked. Hit-testing and dispatch are otherwise AppKit's own.
    @MainActor
    func withFirstMouseAccepted(by classes: [AnyClass], _ body: () throws -> Void) rethrows {
        let selector = #selector(NSView.acceptsFirstMouse(for:))
        let accept: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        let acceptIMP = imp_implementationWithBlock(accept)
        var restore: [(AnyClass, IMP, UnsafePointer<CChar>?)] = []
        for cls in classes {
            guard let method = class_getInstanceMethod(cls, selector) else { continue }
            let encoding = method_getTypeEncoding(method)
            restore.append((cls, method_getImplementation(method), encoding))
            class_replaceMethod(cls, selector, acceptIMP, encoding)
        }
        // A class that only inherited the method keeps the inherited behaviour.
        defer { for (cls, imp, encoding) in restore.reversed() { class_replaceMethod(cls, selector, imp, encoding) } }
        try body()
    }

    /// A real click: mouse-down and mouse-up NSEvents through the window,
    /// which hit-tests and dispatches them as it does the user's clicks.
    @MainActor
    func click(atWindowPoint location: NSPoint, in window: NSWindow, clickCount: Int = 1, settle: TimeInterval = 0.4) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(mouseEvent(type, at: location, in: window, clickCount: clickCount))
            spin(0.02)
        }
        spin(settle)
    }

    @MainActor
    func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        let pressed = type == .leftMouseDown || type == .leftMouseDragged || type == .rightMouseDown
        return NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : clickCount,
            pressure: pressed ? 1 : 0)!
    }

    /// A real mouse-moved event through the window. AppKit routes mouse-moved
    /// events to tracking-area owners only from the window server's own
    /// pointer tracking, which an in-process event cannot reach. A window that
    /// accepts mouse-moved events hands the same event to its first responder,
    /// through the same `sendEvent`; that is the route used here, so the view
    /// under test must be first responder.
    @MainActor
    func moveMouse(toWindowPoint location: NSPoint, in window: NSWindow, settle: TimeInterval = 0.02) {
        window.acceptsMouseMovedEvents = true
        withIdlePointer {
            window.sendEvent(mouseEvent(.mouseMoved, at: location, in: window))
        }
        spin(settle)
    }

    /// Delivers `body`'s pointer events as from a pointer that is shown and
    /// has no button down, whatever the real one on this Mac is doing.
    ///
    /// SwiftUI drops hover while the system hides the pointer: on every
    /// entered and moved event its hover handler asks `+[NSCursor _isHidden]`
    /// and ignores the event when the answer is yes. macOS hides the pointer
    /// in every app as soon as someone types anywhere, until the mouse moves
    /// again, so on a Mac in use the answer depends on whether its owner typed
    /// before the run (typing `swift test` is enough), and hover tests failed
    /// whenever he had. Found 2026-11-13 on macOS 27.2 by counting the calls
    /// and forcing the answer. The PDF view also reads the real
    /// `NSEvent.pressedMouseButtons` to choose its hover cursor, so a button
    /// held anywhere on the Mac would change what it does. Both answers are
    /// fixed while `body` runs and put back after it; nothing outside this
    /// process is touched. A method that has gone away is left alone.
    @MainActor
    func withIdlePointer<T>(_ body: () throws -> T) rethrows -> T {
        var restore: [(Method, IMP)] = []
        if let hidden = class_getClassMethod(NSCursor.self, NSSelectorFromString("_isHidden")) {
            let shown: @convention(block) (AnyClass) -> Bool = { _ in false }
            restore.append((hidden, method_setImplementation(hidden, imp_implementationWithBlock(shown))))
        }
        if let buttons = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)) {
            let none: @convention(block) (AnyClass) -> Int = { _ in 0 }
            restore.append((buttons, method_setImplementation(buttons, imp_implementationWithBlock(none))))
        }
        defer { for (method, original) in restore.reversed() { method_setImplementation(method, original) } }
        return try body()
    }

    /// Runs the run loop until `condition` holds or `timeout` passes, and
    /// says which. For effects that land a little later (a fade, a debounce),
    /// in place of a fixed pause that is too short on a busy machine.
    @MainActor
    @discardableResult
    func waitUntil(timeout: TimeInterval = 3, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if try condition() { return true }
            if Date() >= deadline { return false }
            spin(0.05)
        }
    }

    /// Waits for a hover effect, delivering the pointer event again about
    /// once a second if it has not shown, in case the app dropped it.
    @MainActor
    @discardableResult
    func waitForHover(timeout: TimeInterval = 4, redeliver: () -> Void, _ condition: () throws -> Bool) rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextDelivery = Date().addingTimeInterval(1)
        while true {
            if try condition() { return true }
            if Date() >= deadline { return false }
            if Date() >= nextDelivery {
                redeliver()
                nextDelivery = Date().addingTimeInterval(1)
            }
            spin(0.05)
        }
    }

    /// The view a click at a window point goes to: hit-tested from the
    /// window's frame view, whose coordinates are the window's.
    @MainActor
    func hitView(atWindowPoint location: NSPoint, in window: NSWindow) -> NSView? {
        window.contentView?.superview?.hitTest(location)
    }

    /// The pointer entering, moving in, or leaving `view`, delivered as AppKit
    /// delivers tracking-area events: to the area's owner, with the area set
    /// on entered and exited events. AppKit decides from the window server's
    /// pointer which owners to tell, which an in-process event cannot reach;
    /// here the test names the owner. SwiftUI's `onHover` listens this way.
    @MainActor
    func pointer(_ type: NSEvent.EventType, atWindowPoint location: NSPoint, trackedBy view: NSView) {
        withIdlePointer { deliverPointer(type, atWindowPoint: location, trackedBy: view) }
        spin(0.02)
    }

    @MainActor
    private func deliverPointer(_ type: NSEvent.EventType, atWindowPoint location: NSPoint, trackedBy view: NSView) {
        guard let window = view.window else { return XCTFail("\(view) has no window") }
        let areas = view.trackingAreas.filter { $0.owner === view }
        XCTAssertFalse(areas.isEmpty, "\(Swift.type(of: view)) tracks nothing")
        switch type {
        case .mouseEntered, .mouseExited:
            for area in areas where area.options.contains(.mouseEnteredAndExited) {
                let event = NSEvent.enterExitEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0,
                    trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)!
                XCTAssertTrue(event.trackingArea === area)
                if type == .mouseEntered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
            }
        default:
            if areas.contains(where: { $0.options.contains(.mouseMoved) }) {
                view.mouseMoved(with: mouseEvent(.mouseMoved, at: location, in: window))
            }
        }
    }

    /// A press, drag and release as the app receives them: posted to the
    /// app's event queue, then taken off it and dispatched by `NSApp`. A view
    /// that tracks the drag in its own loop takes the later events from the
    /// queue itself, as it would in the app.
    @MainActor
    func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow, steps: Int = 6) {
        var events = [mouseEvent(.leftMouseDown, at: start, in: window)]
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            events.append(mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window))
        }
        events.append(mouseEvent(.leftMouseUp, at: end, in: window))
        dispatchThroughQueue(events)
    }

    /// Posts the events and pumps the queue until it is empty.
    @MainActor
    func dispatchThroughQueue(_ events: [NSEvent]) {
        for event in events { NSApp.postEvent(event, atStart: false) }
        while let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
        spin(0.1)
    }

    @MainActor
    func keyDown(_ keyCode: UInt16, characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}

/// A text PDF built in the test, one page per string, as one document so
/// its pages carry their own labels (1, 2, …).
enum TestPDF {
    @MainActor
    static func make(pages: [String], size: NSSize = NSSize(width: 500, height: 700)) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return PDFDocument() }
        for text in pages {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                .draw(in: box.insetBy(dx: 34, dy: 30))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data) ?? PDFDocument()
    }
}

/// A page with a figure on it, for region tests: a title and a paragraph,
/// a bar chart whose year labels are real text, its caption below, a note
/// beside it, and a line of plain text under it. Page 2 is plain text.
/// All coordinates are page space (y up) on a 500 × 420 page.
enum FigurePDF {
    static let size = NSSize(width: 500, height: 420)
    /// The chart with its axis labels: what a reader would box.
    static let figure = CGRect(x: 50, y: 128, width: 290, height: 162)
    static let bars = [0.35, 0.5, 0.62, 0.8, 0.7]
    static let years = ["2009", "2011", "2013", "2015", "2017"]
    static let caption = "Figure 2: Turnout by year of rollout"

    @MainActor
    static func make() -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        func text(_ string: String, _ rect: CGRect, size: CGFloat = 11, bold: Bool = false) {
            NSAttributedString(string: string, attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black,
            ]).draw(in: rect)
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text("Effects of early rollout on turnout", CGRect(x: 40, y: 375, width: 420, height: 20), size: 14, bold: true)
        text("Treated municipalities saw turnout rise relative to the synthetic control, and the gap opened in the first election after the reform.",
             CGRect(x: 40, y: 315, width: 420, height: 50))
        // The chart: axes, five bars, the years under them.
        let plot = CGRect(x: 70, y: 150, width: 260, height: 130)
        context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        context.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
        context.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.strokePath()
        for (index, value) in bars.enumerated() {
            let x = plot.minX + 16 + CGFloat(index) * 50
            context.setFillColor(CGColor(srgbRed: 0.25, green: 0.42, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: x, y: plot.minY, width: 28, height: plot.height * value))
            text(years[index], CGRect(x: x - 2, y: plot.minY - 18, width: 40, height: 14), size: 9)
        }
        text(caption, CGRect(x: 50, y: 100, width: 300, height: 16))
        text("Treated places rose fastest in the first two years.", CGRect(x: 360, y: 200, width: 110, height: 70))
        text("Plain words under the figure for the selection test.", CGRect(x: 40, y: 50, width: 420, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text("The design exploits the staggered rollout across regions between 2009 and 2015.", CGRect(x: 40, y: 340, width: 420, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// A real reading session in a temporary folder, with the figure PDF open,
/// so regions can write their pictures and records as in the app. The
/// session folder is removed by `remove()`, which also puts back the
/// auto-highlight preference the session turned off, as it was before the
/// first live session (absence included).
@MainActor
final class RegionTestSession {
    private static var liveSessions = 0
    private static var savedAutoHighlight: Any?
    private var removed = false

    let folder: URL
    let state: AppState
    let document: PDFDocument

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperCompanionRegionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdfURL = folder.appendingPathComponent("figure-paper.pdf")
        try FigurePDF.make().write(to: pdfURL)
        let session = try SessionRepository().createOrLoadSession(
            pdfURL: pdfURL, title: "Figure paper", pageCount: 2, extractedText: "",
            sessionsRoot: folder.appendingPathComponent("Sessions", isDirectory: true)
        )
        document = try XCTUnwrap(PDFDocument(url: pdfURL))
        if Self.liveSessions == 0 {
            Self.savedAutoHighlight = UserDefaults.standard.object(forKey: "PaperCompanion.autoHighlightEnabled")
        }
        Self.liveSessions += 1
        state = AppState()
        state.autoHighlightEnabled = false
        state.manifest = session.manifest
        state.sessionPaths = session.paths
        state.document = document
    }

    var paths: SessionPaths { state.sessionPaths! }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
        guard !removed else { return }
        removed = true
        Self.liveSessions -= 1
        guard Self.liveSessions == 0 else { return }
        if let saved = Self.savedAutoHighlight {
            UserDefaults.standard.set(saved, forKey: "PaperCompanion.autoHighlightEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "PaperCompanion.autoHighlightEnabled")
        }
    }
}

/// The PDF reader and the inspector side by side, as in the app window, in
/// an offscreen window that can receive events.
@MainActor
final class ReaderHarness {
    let state: AppState
    let window: NSWindow
    let host: NSView
    let pdfView: HighlightClickPDFView
    static let pdfWidth: CGFloat = 520

    init(test: XCTestCase, state: AppState, size: NSSize = NSSize(width: 940, height: 760), appearance: NSAppearance? = nil) throws {
        self.state = state
        let hosting = NSHostingView(rootView: HStack(spacing: 0) {
            PDFReaderView(state: state).frame(width: Self.pdfWidth)
            InspectorView()
        }
        .frame(width: size.width, height: size.height)
        // What the app's window draws behind its content.
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(state))
        hosting.frame = NSRect(origin: .zero, size: size)
        // Before the first layout, so everything is drawn in it from the start.
        hosting.appearance = appearance
        host = hosting
        window = test.offscreenWindow(for: hosting)
        window.appearance = appearance
        test.spin()
        pdfView = try XCTUnwrap(test.descendants(of: hosting, as: HighlightClickPDFView.self).first)
    }

    func close(_ test: XCTestCase) {
        test.closeOffscreenWindow(window)
    }

    /// Highlights the first match of `text` the way the user does: a PDF
    /// selection, then Highlight. Leaves nothing selected.
    func highlight(_ text: String, color: String? = nil, test: XCTestCase) throws -> UUID {
        let match = try XCTUnwrap(pdfView.document?.findString(text, withOptions: .caseInsensitive).first, "no “\(text)” in the PDF")
        pdfView.setCurrentSelection(match, animate: false)
        state.addHighlight()
        let id = try XCTUnwrap(state.selectedHighlightID)
        if let color { state.setHighlightColor(id, color: color) }
        pdfView.clearSelection()
        state.clearEntrySelection()
        test.spin(0.1)
        return id
    }

    /// The annotation list's scroll view.
    func annotationList(_ test: XCTestCase) throws -> NSScrollView {
        try XCTUnwrap(test.descendants(of: host, as: NSScrollView.self).first {
            $0.documentView != nil && !($0.documentView is NSTextView) && !($0.superview is PDFView)
        })
    }

    /// Window rects of the card texts in the list, top first. Each Text
    /// draws in a CGDrawingView; page headers sit at the far left.
    func cardTextFrames(_ test: XCTestCase) throws -> [NSRect] {
        let document = try XCTUnwrap(try annotationList(test).documentView)
        let documentLeft = document.convert(document.bounds, to: nil).minX
        var texts: [NSRect] = []
        for view in test.descendants(of: document, as: NSView.self) where String(describing: type(of: view)) == "CGDrawingView" {
            let frame = view.convert(view.bounds, to: nil)
            if frame.minX - documentLeft > 30, !texts.contains(frame) { texts.append(frame) }
        }
        return texts.sorted { $0.maxY > $1.maxY }
    }

    /// The view that tracks the pointer for SwiftUI's hover over the list:
    /// the nearest ancestor of the card at `point` with a mouse-moved
    /// tracking area of its own.
    func hoverTracker(at point: NSPoint, _ test: XCTestCase) throws -> NSView {
        var view = test.hitView(atWindowPoint: point, in: window)
        while let current = view, !current.trackingAreas.contains(where: { $0.owner === current && $0.options.contains(.mouseMoved) }) {
            view = current.superview
        }
        return try XCTUnwrap(view, "no hover tracking above \(point)")
    }

    /// The highlight annotations on the pages, by record ID.
    func annotations() -> [UUID: [PDFAnnotation]] {
        guard let document = pdfView.document else { return [:] }
        var result: [UUID: [PDFAnnotation]] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let id = HighlightClickPDFView.annotationID(of: annotation) { result[id, default: []].append(annotation) }
            }
        }
        return result
    }

    /// The window point at the middle of a highlight's first line.
    func windowPoint(ofHighlight id: UUID) throws -> NSPoint {
        let annotation = try XCTUnwrap(annotations()[id]?.first)
        let page = try XCTUnwrap(annotation.page)
        return windowPoint(NSPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), on: page)
    }

    /// The window point at the middle of the first match of `text`.
    func windowPoint(ofText text: String) throws -> NSPoint {
        let match = try XCTUnwrap(pdfView.document?.findString(text, withOptions: .caseInsensitive).first)
        let page = try XCTUnwrap(match.pages.first)
        let bounds = match.bounds(for: page)
        return windowPoint(NSPoint(x: bounds.midX, y: bounds.midY), on: page)
    }

    func windowPoint(_ pagePoint: NSPoint, on page: PDFPage) -> NSPoint {
        pdfView.convert(pdfView.convert(pagePoint, from: page), to: nil)
    }
}

/// Offscreen PNG rendering for the snapshot tests: `cacheDisplay` into a
/// bitmap, no screen capture. PNGs go to `PAPER_COMPANION_SNAPSHOT_DIR`.
enum SnapshotOutput {
    static func directory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PAPER_COMPANION_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PAPER_COMPANION_SNAPSHOT_DIR to render snapshots")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `rect` is in the view's coordinates; the whole view when nil.
    @MainActor
    static func bitmap(of view: NSView, appearance: NSAppearance, rect: NSRect? = nil) -> NSBitmapImageRep? {
        let area = rect ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: area) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: area, to: rep)
        }
        return rep
    }

    /// The reader as it is on screen. `cacheDisplay` draws what AppKit draws
    /// (the desk behind the pages, the sidebar) but not PDFKit's pages, which
    /// live in layers: page tiles rendered into IOSurfaces, and highlights as
    /// colored layers under a multiply filter. Those are painted on top here
    /// from the real layers: the tiles' own pixels, the highlight layers' own
    /// fills and the page layers' own shadow settings, placed where PDFKit's
    /// page-to-view conversion puts each page. Selection effects and the
    /// arrival flash are not reproduced.
    @MainActor
    static func readerBitmap(of host: NSView, pdfView: PDFView, appearance: NSAppearance, rect: NSRect? = nil) throws -> NSBitmapImageRep {
        let area = rect ?? host.bounds
        let rep = try XCTUnwrap(bitmap(of: host, appearance: appearance, rect: area))
        // The context already maps the bitmap's points to its pixels.
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        let backingScale = CGFloat(rep.pixelsWide) / area.width
        /// A rect in the host's coordinates, in the bitmap's points (y up).
        func device(_ r: NSRect) -> CGRect {
            let y = host.isFlipped ? area.maxY - r.maxY : r.minY - area.minY
            return CGRect(x: r.minX - area.minX, y: y, width: r.width, height: r.height)
        }
        let document = try XCTUnwrap(pdfView.document)
        let pageLayers = allLayers(under: try XCTUnwrap(pdfView.layer)).filter { String(describing: type(of: $0)) == "PDFPageLayer" }
        XCTAssertEqual(pageLayers.count, document.pageCount, "one page layer per page")
        let clip = try XCTUnwrap(pdfView.documentView?.enclosingScrollView?.contentView)
        let images = CIContext()

        for (index, pageLayer) in pageLayers.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let onPage = device(host.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView))
            context.saveGState()
            // Shadows reach past the page; the scroll view's visible area is
            // the limit, as on screen.
            context.clip(to: device(host.convert(clip.bounds, from: clip)))
            context.translateBy(x: onPage.minX, y: onPage.minY)
            context.scaleBy(x: onPage.width / pageLayer.bounds.width, y: onPage.height / pageLayer.bounds.height)
            let shadowScale = backingScale * onPage.width / pageLayer.bounds.width
            for sublayer in sorted(pageLayer.sublayers) {
                paint(sublayer, in: context, multiply: false, shadowScale: shadowScale, images: images)
            }
            context.restoreGState()
        }
        // Views the PDF view hosts above its pages (the box being dragged
        // with the region tool) are drawn by AppKit, under the page layers
        // painted above; paint them again on top, from their own drawing.
        for overlay in pdfView.subviews where overlay is RegionDragOverlay && !overlay.isHidden {
            guard let overlayRep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { continue }
            appearance.performAsCurrentDrawingAppearance { overlay.cacheDisplay(in: overlay.bounds, to: overlayRep) }
            guard let image = overlayRep.cgImage else { continue }
            context.saveGState()
            context.clip(to: device(host.convert(clip.bounds, from: clip)))
            context.draw(image, in: device(host.convert(overlay.bounds, from: overlay)))
            context.restoreGState()
        }
        return rep
    }

    private static func allLayers(under layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { allLayers(under: $0) }
    }

    private static func sorted(_ layers: [CALayer]?) -> [CALayer] {
        (layers ?? []).enumerated().sorted { ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset) }.map(\.element)
    }

    /// One layer of a page in the context, which is in the parent layer's
    /// coordinates (y up, as in PDF page space).
    /// `shadowScale` turns layer units into the device pixels CG shadows use.
    private static func paint(_ layer: CALayer, in context: CGContext, multiply: Bool, shadowScale: CGFloat, images: CIContext) {
        guard !layer.isHidden, layer.opacity > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // The layer's own geometry, transform included: PDFKit turns the
        // annotation layers of a rotated page with it.
        context.translateBy(x: layer.position.x, y: layer.position.y)
        context.concatenate(layer.affineTransform())
        context.translateBy(x: -layer.anchorPoint.x * layer.bounds.width - layer.bounds.minX,
                            y: -layer.anchorPoint.y * layer.bounds.height - layer.bounds.minY)
        context.setAlpha(CGFloat(layer.opacity))
        let multiply = multiply || String(describing: layer.compositingFilter ?? "").contains("multiply")
        context.setBlendMode(multiply ? .multiply : .normal)

        if let path = layer.shadowPath, layer.shadowOpacity > 0 {
            // CG shadow offsets and blur are in device pixels.
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: layer.shadowOffset.width * shadowScale, height: layer.shadowOffset.height * shadowScale),
                blur: layer.shadowRadius * shadowScale,
                color: (layer.shadowColor ?? CGColor(gray: 0, alpha: 1)).copy(alpha: CGFloat(layer.shadowOpacity)))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        if layer.masksToBounds { context.clip(to: layer.bounds) }
        if let background = layer.backgroundColor, background.alpha > 0 {
            context.setFillColor(background)
            context.fill(layer.bounds)
        }
        if let contents = layer.contents {
            var image: CGImage?
            if CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let ci = CIImage(ioSurface: surface)
                image = images.createCGImage(ci, from: ci.extent)
            } else if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                image = (contents as! CGImage)
            } else {
                // A layer PDFKit drew itself (a square annotation): its
                // backing store is private, so Core Animation renders it.
                layer.render(in: context)
            }
            if let image {
                let size = CGSize(width: CGFloat(image.width) / layer.contentsScale, height: CGFloat(image.height) / layer.contentsScale)
                let target = layer.contentsGravity == .bottomLeft ? CGRect(origin: layer.bounds.origin, size: size) : layer.bounds
                context.draw(image, in: target)
            }
        }
        if layer.borderWidth > 0, let border = layer.borderColor, border.alpha > 0 {
            context.setStrokeColor(border)
            context.setLineWidth(layer.borderWidth)
            context.stroke(layer.bounds.insetBy(dx: -layer.borderWidth / 2, dy: -layer.borderWidth / 2))
        }
        for sublayer in sorted(layer.sublayers) {
            paint(sublayer, in: context, multiply: multiply, shadowScale: shadowScale, images: images)
        }
    }

    @MainActor
    @discardableResult
    static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws -> Int {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return data.count
    }

    /// Writes the PNG and returns its size in bytes.
    @MainActor
    @discardableResult
    static func writePNG(of view: NSView, appearance: NSAppearance, rect: NSRect? = nil, to url: URL) throws -> Int {
        let rep = try XCTUnwrap(bitmap(of: view, appearance: appearance, rect: rect), "No bitmap for \(url.lastPathComponent)")
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return data.count
    }
}

/// SwiftUI's accessibility elements, read in-process from the hosting view
/// (the same tree VoiceOver gets; no accessibility permission is involved).
/// Tests use them to find where a control is and what it announces.
extension XCTestCase {
    struct AccessibilityNode {
        let element: NSObject
        let label: String
        let value: String
        /// In the window's coordinates.
        let frame: NSRect
        var center: NSPoint { NSPoint(x: frame.midX, y: frame.midY) }
    }

    /// SwiftUI builds its elements only while an assistive app is using the
    /// app, which it learns from the app's `AXEnhancedUserInterface`
    /// attribute. That attribute is set on this process's own application
    /// object for the walk and put back to what it was after it; nothing
    /// outside the test process is involved.
    @MainActor
    func accessibilityNodes(under view: NSView) -> [AccessibilityNode] {
        guard let window = view.window else { return [] }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: enhanced) }
        spin(0.15)
        var nodes: [AccessibilityNode] = []
        // SwiftUI's elements do not declare the protocol; read them by key.
        func visit(_ object: Any, depth: Int) {
            guard depth < 40, let element = object as? NSObject else { return }
            func read(_ key: String) -> Any? {
                element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
            }
            let label = [read("accessibilityLabel"), read("accessibilityTitle")]
                .compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            let value = read("accessibilityValue").map { "\($0)" } ?? ""
            let frame = (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            nodes.append(AccessibilityNode(element: element, label: label, value: value, frame: window.convertFromScreen(frame)))
            for child in (read("accessibilityChildren") as? [Any]) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(view, depth: 0)
        return nodes
    }

    /// The first element whose label is `label`, optionally only inside `area`
    /// (window coordinates).
    @MainActor
    func accessibilityNode(labeled label: String, under view: NSView, in area: NSRect? = nil) -> AccessibilityNode? {
        accessibilityNodes(under: view).first { node in
            node.label == label && !node.frame.isEmpty && (area.map { $0.contains(node.center) } ?? true)
        }
    }

    /// A real click at `point`, with first mouse accepted by the view the
    /// window hit-tests there (see `withFirstMouseAccepted`).
    @MainActor
    func realClick(atWindowPoint point: NSPoint, in window: NSWindow, settle: TimeInterval = 0.3) {
        guard let hit = hitView(atWindowPoint: point, in: window) else {
            return XCTFail("nothing to click at \(point)")
        }
        withFirstMouseAccepted(by: [type(of: hit)]) {
            click(atWindowPoint: point, in: window, settle: settle)
        }
    }
}

/// Preferences the app stores in `UserDefaults.standard` (the test process's
/// own domain), put back as they were, absence included, when the test ends.
extension XCTestCase {
    /// The recent-papers list is in here because every `AppState` builds a
    /// `RecentPapersStore`, which writes its list on a first-run migration.
    static let appStoredDefaults = ["PaperCompanion.autoHighlightEnabled", "PaperCompanion.recentPapers.v1"]

    func restoreStandardDefaultsAfterTest(_ keys: [String] = appStoredDefaults) {
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }
}
