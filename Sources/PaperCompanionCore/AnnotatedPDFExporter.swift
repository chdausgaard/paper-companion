import Foundation
import PDFKit

/// Writes a copy of the paper with the session's highlights and comments
/// embedded as standard PDF annotations, so they show in Preview, Acrobat,
/// Skim, or a Zotero import. The original is never touched: the copy is a
/// projection of the sidecar records, like `comments.md`, and is regenerated
/// whenever they change.
public enum AnnotatedPDFExporter {
    public enum ExportError: Error, LocalizedError {
        case unreadableSource(URL)
        case writeFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadableSource(let url):
                return "Could not open \(url.lastPathComponent) to embed annotations."
            case .writeFailed(let url):
                return "Could not write the annotated copy to \(url.lastPathComponent)."
            }
        }
    }

    /// Author recorded on every embedded annotation.
    public static let author = "Paper Companion"

    public static func write(
        sourceURL: URL,
        to destination: URL,
        highlights: [HighlightRecord],
        comments: [CommentRecord],
        replies: [UUID: String] = [:]
    ) throws {
        guard let document = PDFDocument(url: sourceURL) else {
            throw ExportError.unreadableSource(sourceURL)
        }
        embed(into: document, highlights: highlights, comments: comments, replies: replies)

        // Write beside the destination and swap, so a reader that opens the
        // copy mid-write never sees a truncated file.
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard document.write(to: temporary) else {
            throw ExportError.writeFailed(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Adds the annotations to an in-memory document. Separated from `write`
    /// so tests can inspect the result without a source file on disk.
    public static func embed(
        into document: PDFDocument,
        highlights: [HighlightRecord],
        comments: [CommentRecord],
        replies: [UUID: String] = [:]
    ) {
        let live = comments.filter { $0.status != "deleted" }
        let active = highlights.filter { $0.deletedAt == nil }
        let activeIDs = Set(active.map(\.id))

        for highlight in active {
            let linked = live
                .filter { $0.highlightID == highlight.id }
                .sorted { $0.createdAt < $1.createdAt }
            let note = noteText(for: linked, replies: replies)
            for location in highlight.locations {
                guard let page = document.page(at: location.pageIndex),
                      let annotation = highlightAnnotation(for: location) else { continue }
                annotation.color = (HighlightColor(rawValue: highlight.color) ?? .yellow).nsColor
                annotation.contents = note
                annotation.userName = author
                annotation.modificationDate = linked.last?.updatedAt ?? highlight.createdAt
                page.addAnnotation(annotation)
            }
        }

        // Page-only and orphaned comments become note icons down the top-left
        // margin of their page, in the order they were written.
        var notesPerPage: [Int: Int] = [:]
        let standalone = live
            .filter { comment in
                guard let highlightID = comment.highlightID else { return true }
                return !activeIDs.contains(highlightID)
            }
            .sorted { $0.createdAt < $1.createdAt }
        for comment in standalone {
            guard let pageIndex = comment.pageIndex, let page = document.page(at: pageIndex) else { continue }
            let slot = notesPerPage[pageIndex, default: 0]
            notesPerPage[pageIndex] = slot + 1
            let box = page.bounds(for: .cropBox)
            let size: CGFloat = 20
            let bounds = NSRect(
                x: box.minX + 6,
                y: box.maxY - 6 - size - CGFloat(slot) * (size + 4),
                width: size,
                height: size
            )
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.iconType = .note
            annotation.color = comment.kind == .quiet ? .systemGray : .systemYellow
            annotation.contents = noteText(for: [comment], replies: replies)
            annotation.userName = author
            annotation.modificationDate = comment.updatedAt
            page.addAnnotation(annotation)
        }
    }

    /// A highlight annotation whose quad points follow the line rectangles, so
    /// other viewers draw it line by line rather than as one block. PDFKit
    /// takes the points relative to the bounds and writes them page-absolute.
    private static func highlightAnnotation(for location: HighlightLocation) -> PDFAnnotation? {
        let rects = location.lineRects.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        guard let first = rects.first else { return nil }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = .systemYellow
        annotation.quadrilateralPoints = rects.flatMap { rect -> [NSValue] in
            let x0 = rect.minX - bounds.minX
            let x1 = rect.maxX - bounds.minX
            let y0 = rect.minY - bounds.minY
            let y1 = rect.maxY - bounds.minY
            return [
                NSPoint(x: x0, y: y1), NSPoint(x: x1, y: y1),
                NSPoint(x: x0, y: y0), NSPoint(x: x1, y: y0)
            ].map { NSValue(point: $0) }
        }
        return annotation
    }

    /// The popup text: comments verbatim, margin notes labelled, agent replies
    /// appended and attributed so they are never mistaken for the user's words.
    static func noteText(for comments: [CommentRecord], replies: [UUID: String]) -> String {
        var blocks: [String] = []
        for comment in comments {
            var block = comment.kind == .quiet ? "Margin note: \(comment.verbatim)" : comment.verbatim
            if let reply = replies[comment.id] {
                block += "\n\n— Agent: \(reply)"
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n———\n\n")
    }
}
