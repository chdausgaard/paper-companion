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
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .windowBackgroundColor
        context.coordinator.connect(to: pdfView)
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
    final class Coordinator: NSObject {
        private weak var pdfView: PDFView?
        private weak var state: AppState?
        private var renderedHighlightSignature = ""
        private var renderedAnnotations: [UUID: [PDFAnnotation]] = [:]
        private var renderedSelectedID: UUID?
        private var renderedColors: [UUID: String] = [:]
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
            searchResults = []
            searchIndex = 0
            lastSearchQuery = ""
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
                        annotation.color = (HighlightColor(rawValue: highlight.color) ?? .yellow).nsColor
                            .withAlphaComponent(highlight.id == selectedID ? 0.65 : 0.42)
                        annotation.userName = "PaperCompanion:\(highlight.id.uuidString)"
                        page.addAnnotation(annotation)
                        drawn.append(annotation)
                    }
                }
                renderedAnnotations[id] = drawn
            }
            renderedColors = active.mapValues(\.color)
            renderedSelectedID = selectedID
            renderedHighlightSignature = signature
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

    private func highlightID(at event: NSEvent) -> UUID? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        for annotation in page.annotations.reversed() where annotation.bounds.contains(pagePoint) {
            if let name = annotation.userName, name.hasPrefix("PaperCompanion:"),
               let id = UUID(uuidString: String(name.dropFirst("PaperCompanion:".count))) { return id }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let id = highlightID(at: event)
        super.mouseDown(with: event)
        guard event.clickCount == 1, let id,
              currentSelection?.string?.isEmpty ?? true else { return }
        window?.makeFirstResponder(self)
        onHighlightClick?(id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = highlightID(at: event) else { return super.menu(for: event) }
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
