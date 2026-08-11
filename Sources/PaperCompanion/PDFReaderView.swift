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
        let pdfView = PDFView()
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
        context.coordinator.renderHighlights(state.activeHighlights, in: pdfView)
        context.coordinator.navigateIfNeeded(
            requestID: state.navigationRequestID,
            pageIndex: state.navigationPageIndex,
            in: pdfView
        )
        context.coordinator.searchIfNeeded(
            requestID: state.searchRequestID,
            query: state.searchQuery,
            in: pdfView
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var pdfView: PDFView?
        private weak var state: AppState?
        private var renderedHighlightSignature = ""
        private var lastNavigationRequestID: UUID?
        private var lastSearchRequestID: UUID?
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
            searchResults = []
            searchIndex = 0
            lastSearchQuery = ""
        }

        func renderHighlights(_ highlights: [HighlightRecord], in pdfView: PDFView) {
            let signature = highlights
                .map { $0.id.uuidString + ($0.deletedAt == nil ? ":active" : ":deleted") }
                .joined(separator: "|")
            guard signature != renderedHighlightSignature else { return }

            if let document = pdfView.document {
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else { continue }
                    for annotation in page.annotations where annotation.userName?.hasPrefix("PaperCompanion:") == true {
                        page.removeAnnotation(annotation)
                    }
                }

                for highlight in highlights where highlight.deletedAt == nil {
                    for location in highlight.locations {
                        guard let page = document.page(at: location.pageIndex) else { continue }
                        for rect in location.lineRects {
                            let bounds = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                            annotation.color = NSColor.systemYellow.withAlphaComponent(0.42)
                            annotation.userName = "PaperCompanion:\(highlight.id.uuidString)"
                            page.addAnnotation(annotation)
                        }
                    }
                }
            }
            renderedHighlightSignature = signature
        }

        func navigateIfNeeded(requestID: UUID, pageIndex: Int?, in pdfView: PDFView) {
            guard lastNavigationRequestID != requestID,
                  let pageIndex,
                  let page = pdfView.document?.page(at: pageIndex) else { return }
            lastNavigationRequestID = requestID
            pdfView.go(to: page)
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

        @objc private func selectionChanged() {
            guard let pdfView, let state else { return }
            let snapshot = makeSelectionSnapshot(pdfView.currentSelection, document: pdfView.document)
            let allowAutoHighlight = !suppressAutoHighlight
            Task { @MainActor in
                state.selectionChanged(snapshot, allowAutoHighlight: allowAutoHighlight)
            }
        }

        @objc private func pageChanged() {
            guard let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage,
                  let state else { return }
            let index = document.index(for: page)
            let label = page.label ?? String(index + 1)
            let text = page.string ?? ""
            Task { @MainActor in
                state.pageChanged(index: index, label: label, text: text)
            }
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
