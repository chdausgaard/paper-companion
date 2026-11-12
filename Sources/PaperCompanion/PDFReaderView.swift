import AppKit
import PDFKit
import PaperCompanionCore
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = HighlightClickPDFView()
        pdfView.onHighlightClick = { [weak state] id in
            state?.highlightClicked(id)
        }
        pdfView.onDeleteKey = { [weak state] in
            state?.deleteSelectedEntry() ?? false
        }
        pdfView.onHighlightDelete = { [weak state] id in state?.deleteHighlight(id) }
        pdfView.onHighlightColor = { [weak state] id, color in state?.setHighlightColor(id, color: color) }
        pdfView.onAnnotationHoverChange = { [weak coordinator = context.coordinator] id in
            coordinator?.pageHoverChanged(id)
        }
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        // The system's under-page "desk" behind the pages (PDFView's scroll
        // view draws it as the matching material), so the white pages read
        // as sheets lifted off it rather than as part of the window.
        pdfView.backgroundColor = .underPageBackgroundColor
        context.coordinator.connect(to: pdfView)
        state.annotationHover.cardHoverObserver = context.coordinator
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== state.document {
            pdfView.document = state.document
            context.coordinator.resetForDocument()
        }
        context.coordinator.renderHighlights(
            state.activeHighlights,
            selectedID: state.selectedHighlightID,
            in: pdfView
        )
        context.coordinator.navigateIfNeeded(
            requestID: state.navigationRequestID,
            pageIndex: state.navigationPageIndex,
            highlight: state.navigationHighlightID.flatMap { id in
                state.activeHighlights.first { $0.id == id }
            },
            in: pdfView
        )
        context.coordinator.searchIfNeeded(
            requestID: state.searchRequestID,
            query: state.searchQuery,
            in: pdfView
        )
        context.coordinator.focusIfNeeded(requestID: state.pdfFocusRequestID, in: pdfView)
    }

    @MainActor
    final class Coordinator: NSObject, AnnotationHoverObserver {
        private weak var pdfView: PDFView?
        private weak var state: AppState?
        private var renderedHighlightSignature = ""
        private var renderedAnnotations: [UUID: [PDFAnnotation]] = [:]
        private var renderedSelectedID: UUID?
        private var renderedColors: [UUID: String] = [:]
        /// The highlight drawn brighter because the pointer is on it, on the
        /// page or on its card.
        private var emphasizedID: UUID?
        private var lastNavigationRequestID: UUID?
        private var lastSearchRequestID: UUID?
        private var lastFocusRequestID: UUID?
        private var searchResults: [PDFSelection] = []
        private var searchIndex = 0
        private var lastSearchQuery = ""
        private var suppressAutoHighlight = false

        init(state: AppState) {
            self.state = state
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func connect(to pdfView: PDFView) {
            self.pdfView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        func resetForDocument() {
            renderedHighlightSignature = ""
            renderedAnnotations = [:]
            renderedSelectedID = nil
            renderedColors = [:]
            emphasizedID = nil
            state?.annotationHover.reset()
            reconcileHover()
            searchResults = []
            searchIndex = 0
            lastSearchQuery = ""
        }

        /// Highlight fill in three clear steps: brighter with the pointer on
        /// it, stronger when selected, strongest when both. One place, so
        /// every path draws the same states.
        static func highlightFill(_ color: String, selected: Bool, hovered: Bool) -> NSColor {
            let alpha: CGFloat
            switch (selected, hovered) {
            case (false, false): alpha = 0.42
            case (false, true): alpha = 0.57
            case (true, false): alpha = 0.72
            case (true, true): alpha = 0.88
            }
            return (HighlightColor(rawValue: color) ?? .yellow).nsColor.withAlphaComponent(alpha)
        }

        // MARK: Hover

        /// The annotation under the pointer on the page changed.
        func pageHoverChanged(_ id: UUID?) {
            state?.annotationHover.setPageHovered(id)
            updateEmphasis()
        }

        func cardHoverDidChange() {
            updateEmphasis()
        }

        /// Brings every place hover lives into agreement after the drawn
        /// annotations changed without a pointer event (a highlight deleted
        /// or restored under a still pointer, a new document): the view
        /// hit-tests again where the pointer last was and sets the cursor
        /// PDFKit would choose there, the shared hover object takes the
        /// result, and the page emphasis follows it and the card hover.
        private func reconcileHover() {
            guard let hover = state?.annotationHover else { return }
            let pageID = (pdfView as? HighlightClickPDFView)?.refreshHover()
            if hover.pageHoveredID != pageID { hover.setPageHovered(pageID) }
            updateEmphasis()
        }

        /// Restyles only the highlight that gained the pointer and the one
        /// that lost it, changing their color in place: no annotation is added
        /// or removed, and no other highlight is touched, so a paper with a
        /// hundred highlights does not stutter as the pointer moves.
        private func updateEmphasis() {
            guard let hover = state?.annotationHover else { return }
            // The page wins: the card side lags by its delay.
            let wanted = hover.pageHoveredID ?? hover.cardHoveredID
            let target = wanted.flatMap { renderedAnnotations[$0] == nil ? nil : $0 }
            guard target != emphasizedID else { return }
            let previous = emphasizedID
            emphasizedID = target
            for id in [previous, target].compactMap({ $0 }) {
                guard let color = renderedColors[id] else { continue }
                let fill = Self.highlightFill(color, selected: id == renderedSelectedID, hovered: id == emphasizedID)
                for annotation in renderedAnnotations[id] ?? [] { annotation.color = fill }
            }
        }

        /// Adds and removes only what changed. Rebuilding every annotation on
        /// every selection change made clicking a highlight visibly stutter on
        /// papers with a hundred of them.
        func renderHighlights(
            _ highlights: [HighlightRecord],
            selectedID: UUID?,
            in pdfView: PDFView
        ) {
            let signature = highlights
                .map { $0.id.uuidString + $0.color + ($0.deletedAt == nil ? ":active" : ":deleted") }
                .joined(separator: "|") + "#\(selectedID?.uuidString ?? "none")"
            guard signature != renderedHighlightSignature, let document = pdfView.document else { return }

            let active = Dictionary(
                highlights.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for (id, annotations) in renderedAnnotations where active[id] == nil {
                for annotation in annotations { annotation.page?.removeAnnotation(annotation) }
                renderedAnnotations[id] = nil
                // A deleted highlight under the pointer: forget the hover, or
                // its card would come back lit after an undo.
                // Its annotations are gone; `reconcileHover` below settles
                // what the pointer is on now.
                if emphasizedID == id { emphasizedID = nil }
            }

            var toDraw = Set(active.keys.filter { renderedAnnotations[$0] == nil || renderedColors[$0] != active[$0]?.color })
            if renderedSelectedID != selectedID {
                if let previous = renderedSelectedID, active[previous] != nil { toDraw.insert(previous) }
                if let selectedID, active[selectedID] != nil { toDraw.insert(selectedID) }
            }

            for id in toDraw {
                guard let highlight = active[id] else { continue }
                for annotation in renderedAnnotations[id] ?? [] {
                    annotation.page?.removeAnnotation(annotation)
                }
                var drawn: [PDFAnnotation] = []
                for location in highlight.locations {
                    guard let page = document.page(at: location.pageIndex) else { continue }
                    for rect in location.lineRects {
                        let bounds = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                        annotation.color = Self.highlightFill(
                            highlight.color,
                            selected: highlight.id == selectedID,
                            hovered: highlight.id == emphasizedID
                        )
                        annotation.userName = HighlightClickPDFView.annotationNamePrefix + highlight.id.uuidString
                        page.addAnnotation(annotation)
                        drawn.append(annotation)
                    }
                }
                renderedAnnotations[id] = drawn
            }
            renderedColors = active.mapValues(\.color)
            renderedSelectedID = selectedID
            renderedHighlightSignature = signature
            reconcileHover()
        }

        func navigateIfNeeded(
            requestID: UUID,
            pageIndex: Int?,
            highlight: HighlightRecord?,
            in pdfView: PDFView
        ) {
            guard lastNavigationRequestID != requestID,
                  let pageIndex,
                  let page = pdfView.document?.page(at: pageIndex) else { return }
            lastNavigationRequestID = requestID

            // Scrolling to the page alone leaves the reader hunting for the passage.
            // Aim at the highlight itself, with margin so it lands inside the view
            // rather than flush against its top edge.
            guard let highlight,
                  let destination = enclosingRect(for: highlight, pageIndex: pageIndex) else {
                pdfView.go(to: page)
                return
            }
            let margin = max(destination.height, 24) * 3
            let padded = destination.insetBy(dx: 0, dy: -margin).intersection(page.bounds(for: pdfView.displayBox))
            pdfView.go(to: padded.isNull ? destination : padded, on: page)
            flash(highlight: highlight, pageIndex: pageIndex, in: pdfView)
        }

        /// Union of the highlight's line rectangles on the page being navigated to.
        private func enclosingRect(for highlight: HighlightRecord, pageIndex: Int) -> NSRect? {
            let rects = highlight.locations
                .filter { $0.pageIndex == pageIndex }
                .flatMap(\.lineRects)
                .map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            guard let first = rects.first else { return nil }
            return rects.dropFirst().reduce(first) { $0.union($1) }
        }

        /// Briefly overlay the highlight so the eye catches it on arrival. The
        /// overlay is removed again; the persistent annotation underneath is
        /// what keeps the highlight visible.
        private func flash(highlight: HighlightRecord, pageIndex: Int, in pdfView: PDFView) {
            guard let page = pdfView.document?.page(at: pageIndex) else { return }
            let overlays: [PDFAnnotation] = highlight.locations
                .filter { $0.pageIndex == pageIndex }
                .flatMap(\.lineRects)
                .map { rect in
                    let bounds = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = (HighlightColor(rawValue: highlight.color) ?? .yellow).nsColor.withAlphaComponent(0.35)
                    annotation.userName = "PaperCompanionFlash"
                    page.addAnnotation(annotation)
                    return annotation
                }
            guard !overlays.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                for overlay in overlays { page.removeAnnotation(overlay) }
            }
        }

        func focusIfNeeded(requestID: UUID, in pdfView: PDFView) {
            guard lastFocusRequestID != nil, lastFocusRequestID != requestID else {
                lastFocusRequestID = requestID
                return
            }
            lastFocusRequestID = requestID
            pdfView.window?.makeFirstResponder(pdfView)
            // Esc in the Reading Notes window's comment box asks for this
            // while that window is key; the keyboard only reaches the PDF if
            // its window becomes key too.
            if let window = pdfView.window, !window.isKeyWindow { window.makeKey() }
        }

        func searchIfNeeded(requestID: UUID, query: String, in pdfView: PDFView) {
            guard lastSearchRequestID != requestID else { return }
            lastSearchRequestID = requestID
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let document = pdfView.document else { return }

            if trimmed != lastSearchQuery {
                searchResults = document.findString(trimmed, withOptions: .caseInsensitive)
                searchIndex = 0
                lastSearchQuery = trimmed
            } else if !searchResults.isEmpty {
                searchIndex = (searchIndex + 1) % searchResults.count
            }
            if searchResults.isEmpty {
                state?.statusMessage = "No matches for “\(trimmed)”"
                return
            }
            let selection = searchResults[searchIndex]
            suppressAutoHighlight = true
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.suppressAutoHighlight = false
            }
            state?.statusMessage = "Match \(searchIndex + 1) of \(searchResults.count)"
        }

        // PDFKit posts these on the main thread; handling them synchronously
        // keeps a highlight click ordered after the selection it clears.
        @objc private func selectionChanged() {
            guard let pdfView, let state else { return }
            let snapshot = makeSelectionSnapshot(pdfView.currentSelection, document: pdfView.document)
            state.selectionChanged(snapshot, allowAutoHighlight: !suppressAutoHighlight)
        }

        @objc private func pageChanged() {
            guard let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage,
                  let state else { return }
            let index = document.index(for: page)
            state.pageChanged(index: index, label: page.label ?? String(index + 1), text: page.string ?? "")
        }

        private func makeSelectionSnapshot(_ selection: PDFSelection?, document: PDFDocument?) -> SelectionSnapshot? {
            guard let selection,
                  let document,
                  let selectedText = selection.string,
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            var locations: [HighlightLocation] = []
            for page in selection.pages {
                let pageIndex = document.index(for: page)
                var lineRects: [RectRecord] = []
                for lineSelection in selection.selectionsByLine() {
                    guard lineSelection.pages.contains(page) else { continue }
                    let rect = lineSelection.bounds(for: page)
                    if !rect.isEmpty {
                        lineRects.append(RectRecord(
                            x: rect.origin.x,
                            y: rect.origin.y,
                            width: rect.size.width,
                            height: rect.size.height
                        ))
                    }
                }

                var ranges: [TextRangeRecord] = []
                for rangeIndex in 0..<selection.numberOfTextRanges(on: page) {
                    let range = selection.range(at: rangeIndex, on: page)
                    ranges.append(TextRangeRecord(location: range.location, length: range.length))
                }
                let crop = page.bounds(for: .cropBox)
                locations.append(HighlightLocation(
                    pageIndex: pageIndex,
                    pageLabel: page.label ?? String(pageIndex + 1),
                    lineRects: lineRects,
                    textRanges: ranges,
                    cropBox: RectRecord(
                        x: crop.origin.x,
                        y: crop.origin.y,
                        width: crop.size.width,
                        height: crop.size.height
                    ),
                    rotation: page.rotation
                ))
            }

            let surrounding = surroundingText(for: selection, selectedText: selectedText)
            return SelectionSnapshot(
                selectedText: selectedText,
                prefix: surrounding.prefix,
                suffix: surrounding.suffix,
                locations: locations
            )
        }

        private func surroundingText(for selection: PDFSelection, selectedText: String) -> (prefix: String, suffix: String) {
            guard let page = selection.pages.first,
                  let pageText = page.string,
                  selection.numberOfTextRanges(on: page) > 0 else {
                return ("", "")
            }
            let range = selection.range(at: 0, on: page)
            let text = pageText as NSString
            guard range.location != NSNotFound, range.location <= text.length else { return ("", "") }
            let prefixStart = max(0, range.location - 500)
            let prefixRange = NSRange(location: prefixStart, length: range.location - prefixStart)
            let suffixStart = min(text.length, range.location + range.length)
            let suffixLength = min(500, text.length - suffixStart)
            return (
                text.substring(with: prefixRange),
                text.substring(with: NSRange(location: suffixStart, length: suffixLength))
            )
        }
    }
}

/// A PDFView that reports single clicks on Paper Companion highlight
/// annotations. Selection behaviour is untouched: `super` runs first, and the
/// click only counts when it did not become a drag.
final class HighlightClickPDFView: PDFView {
    var onHighlightClick: ((UUID) -> Void)?
    /// ⌫ or ⌦ while this view has focus. Returns true when it consumed the key.
    var onDeleteKey: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           onDeleteKey?() == true {
            return
        }
        super.keyDown(with: event)
    }

    var onHighlightDelete: ((UUID) -> Void)?
    var onHighlightColor: ((UUID, String) -> Void)?
    private var menuHighlightID: UUID?

    // MARK: Hit testing

    static let annotationNamePrefix = "PaperCompanion:"

    /// The record ID a Paper Companion annotation was drawn for, from the
    /// `userName` it was tagged with. Nil for the PDF's own annotations and
    /// for the arrival flash.
    static func annotationID(of annotation: PDFAnnotation) -> UUID? {
        guard let name = annotation.userName, name.hasPrefix(annotationNamePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(annotationNamePrefix.count)))
    }

    /// The Paper Companion annotation under a point in this view's
    /// coordinates: the topmost one whose bounds contain it. Clicks, the
    /// context menu and hover all ask this, so they always agree.
    func annotationID(at point: NSPoint) -> UUID? {
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() where annotation.bounds.contains(pagePoint) {
            if let id = Self.annotationID(of: annotation) { return id }
        }
        return nil
    }

    private func annotationID(at event: NSEvent) -> UUID? {
        annotationID(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Hover

    /// Called only when the annotation under the pointer changes.
    var onAnnotationHoverChange: ((UUID?) -> Void)?
    private(set) var hoveredAnnotationID: UUID?
    private var hoverTrackingArea: NSTrackingArea?
    private weak var lastMovedEvent: NSEvent?
    /// Where the pointer last was, from the events this view received; nil
    /// once it left. Scrolling hit-tests here again.
    private var pointerLocationInWindow: NSPoint?
    private weak var observedClipView: NSClipView?

    /// PDFView keeps a tracking area of its own (no mouse-moved option); this
    /// one adds mouse-moved and entered/exited for hover. Same activity rule
    /// as PDFView's: the key window only, where the cursor is ours to set.
    private func installHoverTrackingArea() {
        if let hoverTrackingArea, trackingAreas.contains(hoverTrackingArea) { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installHoverTrackingArea()
        observeScrolling()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTrackingArea()
    }

    /// Scrolling moves the pages under a still pointer, and scroll-wheel
    /// events go to PDFView's inner scroll view, not to this view. Its clip
    /// view reports every scroll, from the wheel, the keyboard or navigation.
    private func observeScrolling() {
        guard let clip = subviews.lazy.compactMap({ $0 as? NSScrollView }).first?.contentView,
              clip !== observedClipView else { return }
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: clip
        )
        observedClipView = clip
    }

    @objc private func clipViewScrolled(_ notification: Notification) {
        guard let location = pointerLocationInWindow else { return }
        pointerMoved(to: location)
    }

    override func mouseMoved(with event: NSEvent) {
        // The window can hand one event to this view twice: through the
        // hover tracking area and through PDFView's own route while it is
        // first responder. PDFView handled it the first time.
        guard event !== lastMovedEvent else { return }
        lastMovedEvent = event
        pointerLocationInWindow = event.locationInWindow
        updateHover(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
        if hoveredAnnotationID != nil { setHoverCursor() }
    }

    /// The pointer is at `location` (window coordinates) without a
    /// mouse-moved event having said so: after a scroll, or after a drag that
    /// PDFKit tracked itself. Reports a change of hover and sets the cursor.
    private func pointerMoved(to location: NSPoint) {
        pointerLocationInWindow = location
        let before = hoveredAnnotationID
        updateHover(at: convert(location, from: nil))
        if hoveredAnnotationID != before { applyCursor() }
    }

    /// The cursor for where the pointer last was: the pointing hand over one
    /// of our annotations, otherwise what PDFKit chooses for that spot. Only
    /// while this window has the keyboard (or none has, as when the app is in
    /// the background, where the system ignores it anyway).
    private func applyCursor() {
        guard let location = pointerLocationInWindow, let window,
              window.isKeyWindow || NSApp.keyWindow == nil else { return }
        if hoveredAnnotationID != nil {
            setHoverCursor()
        } else {
            super.setCursorFor(areaOfInterest(for: convert(location, from: nil)))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea, hoverTrackingArea != nil else {
            return super.mouseEntered(with: event)
        }
        pointerLocationInWindow = event.locationInWindow
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea, hoverTrackingArea != nil else {
            return super.mouseExited(with: event)
        }
        pointerLocationInWindow = nil
        updateHover(at: nil)
    }

    /// PDFView sets the I-beam, arrow or link cursor here as the pointer
    /// moves. Over one of our annotations it is the pointing hand, as for a
    /// link, because a click there selects it. Not while a button is down:
    /// a drag that started on a highlight is selecting text.
    override func setCursorFor(_ area: PDFAreaOfInterest) {
        if hoveredAnnotationID != nil, NSEvent.pressedMouseButtons == 0 {
            NSCursor.pointingHand.set()
        } else {
            super.setCursorFor(area)
        }
    }

    private func setHoverCursor() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        NSCursor.pointingHand.set()
    }

    /// Hit-tests on every move but reports only a change.
    private func updateHover(at point: NSPoint?) {
        let id = point.flatMap { annotationID(at: $0) }
        guard id != hoveredAnnotationID else { return }
        hoveredAnnotationID = id
        onAnnotationHoverChange?(id)
    }

    /// Hit-tests again where the pointer last was, after the annotations
    /// under it changed without a pointer event. Does not report: the
    /// coordinator calls this inside its own update and settles the rest.
    /// Sets the cursor when the answer changed, so a hand does not linger
    /// over a highlight that was deleted.
    @discardableResult
    func refreshHover() -> UUID? {
        let id = pointerLocationInWindow.flatMap { annotationID(at: convert($0, from: nil)) }
        guard id != hoveredAnnotationID else { return id }
        hoveredAnnotationID = id
        applyCursor()
        return id
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let id = annotationID(at: event)
        super.mouseDown(with: event)
        // PDFKit tracks a drag inside `super` and takes its dragged and up
        // events, so no mouse-moved follows a selection drag: the pointer may
        // now be far from where the button went down.
        pointerMoved(to: pointerLocationAfterTracking(startedWith: event))
        guard event.clickCount == 1, let id,
              currentSelection?.string?.isEmpty ?? true else { return }
        window?.makeFirstResponder(self)
        onHighlightClick?(id)
    }

    /// Where the pointer is once PDFKit's tracking of a press has returned:
    /// the last event it took from the queue, if that was this press's
    /// drag or release in this window.
    private func pointerLocationAfterTracking(startedWith event: NSEvent) -> NSPoint {
        if let last = NSApp.currentEvent, last.window === window,
           [.leftMouseDragged, .leftMouseUp].contains(last.type) {
            return last.locationInWindow
        }
        return event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        pointerMoved(to: event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = annotationID(at: event) else { return super.menu(for: event) }
        clearSelection()
        window?.makeFirstResponder(self)
        onHighlightClick?(id)
        menuHighlightID = id
        let menu = NSMenu(title: "Highlight")
        for color in HighlightColor.allCases {
            let item = NSMenuItem(title: color.rawValue.capitalized, action: #selector(changeHighlightColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.white.setFill()
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                circle.fill()
                color.nsColor.withAlphaComponent(0.65).setFill()
                circle.fill()
                return true
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Highlight and Comments", action: #selector(deleteMenuHighlight(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func changeHighlightColor(_ sender: NSMenuItem) {
        guard let id = menuHighlightID, let color = sender.representedObject as? String else { return }
        onHighlightColor?(id, color)
    }

    @objc private func deleteMenuHighlight(_ sender: NSMenuItem) {
        guard let id = menuHighlightID else { return }
        onHighlightDelete?(id)
    }
}
