import Foundation
import PDFKit
import XCTest
@testable import PaperCompanionCore

final class AnnotatedPDFExporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotatedPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func blankPDF(pages: Int) throws -> URL {
        let document = PDFDocument()
        for index in 0..<pages { document.insert(PDFPage(), at: index) }
        let url = temporaryDirectory.appendingPathComponent("source.pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func highlight(page: Int, lines: [RectRecord]) -> HighlightRecord {
        HighlightRecord(
            quote: "quoted",
            prefix: "",
            suffix: "",
            locations: [HighlightLocation(pageIndex: page, pageLabel: String(page + 1), lineRects: lines, textRanges: [])]
        )
    }

    func testHighlightsBecomeQuadPointHighlightsWithCommentsAsPopupText() throws {
        let source = try blankPDF(pages: 2)
        let twoLines = highlight(page: 1, lines: [
            RectRecord(x: 72, y: 700, width: 400, height: 12),
            RectRecord(x: 72, y: 686, width: 150, height: 12)
        ])
        let comment = CommentRecord(highlightID: twoLines.id, pageIndex: 1, pageLabel: "2", verbatim: "Too strong.")
        let reply = "Agree; reserve list."
        let destination = temporaryDirectory.appendingPathComponent("out.pdf")

        try AnnotatedPDFExporter.write(
            sourceURL: source, to: destination,
            highlights: [twoLines], comments: [comment], replies: [comment.id: reply]
        )

        let written = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(written.page(at: 0)?.annotations.count, 0)
        let annotations = try XCTUnwrap(written.page(at: 1)?.annotations)
        XCTAssertEqual(annotations.count, 1)
        let annotation = annotations[0]
        XCTAssertEqual(annotation.type, "Highlight")
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 8, "two lines, four points each")
        XCTAssertEqual(annotation.bounds, NSRect(x: 72, y: 686, width: 400, height: 26))
        XCTAssertEqual(annotation.contents, "Too strong.\n\n— Agent: Agree; reserve list.")
        XCTAssertEqual(annotation.userName, AnnotatedPDFExporter.author)

        // The original is untouched.
        XCTAssertEqual(PDFDocument(url: source)?.page(at: 1)?.annotations.count, 0)
    }

    func testPageOnlyMarginAndDeletedRecordsAreHandled() throws {
        let source = try blankPDF(pages: 1)
        let document = try XCTUnwrap(PDFDocument(url: source))
        var removed = highlight(page: 0, lines: [RectRecord(x: 10, y: 10, width: 10, height: 10)])
        removed.deletedAt = Date()
        let orphan = CommentRecord(highlightID: removed.id, pageIndex: 0, pageLabel: "1", verbatim: "orphaned")
        let pageOnly = CommentRecord(pageIndex: 0, pageLabel: "1", verbatim: "page-level", kind: .quiet)
        let deleted = CommentRecord(pageIndex: 0, pageLabel: "1", verbatim: "gone", status: "deleted")

        AnnotatedPDFExporter.embed(into: document, highlights: [removed], comments: [orphan, pageOnly, deleted])

        // PDFKit pairs every note icon with a Popup annotation; only the notes count.
        let annotations = try XCTUnwrap(document.page(at: 0)?.annotations).filter { $0.type != "Popup" }
        XCTAssertEqual(annotations.count, 2, "no highlight for the removed one, no note for the deleted comment")
        XCTAssertTrue(annotations.allSatisfy { $0.type == "Text" })
        XCTAssertEqual(Set(annotations.compactMap(\.contents)), ["orphaned", "Margin note: page-level"])
        XCTAssertNotEqual(annotations[0].bounds.minY, annotations[1].bounds.minY, "notes on one page are stacked, not overlaid")
    }

    func testAnnotatedPDFIsNamedAfterTheSourceFile() {
        let paths = SessionPaths(root: URL(fileURLWithPath: "/tmp/s.reading"))
        let manifest = SessionManifest(title: "T", sourcePDFPath: "/papers/Bos_Egerod 2026.pdf", sourcePDFFingerprint: "x", pageCount: 1)
        XCTAssertEqual(paths.annotatedPDF(for: manifest).lastPathComponent, "Bos_Egerod 2026-annotated.pdf")
    }
}
