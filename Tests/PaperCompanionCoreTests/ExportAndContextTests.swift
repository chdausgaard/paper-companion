import Foundation
import XCTest
@testable import PaperCompanionCore

final class ExportAndContextTests: XCTestCase {
    func testMarginNotesAreLabelledDistinctlyFromComments() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let highlightID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let highlight = HighlightRecord(
            id: highlightID,
            quote: "An elegant derivation.",
            prefix: "",
            suffix: "",
            locations: [HighlightLocation(pageIndex: 2, pageLabel: "3", lineRects: [], textRanges: [])],
            createdAt: timestamp
        )
        let quiet = CommentRecord(
            highlightID: highlightID,
            pageIndex: 2,
            pageLabel: "3",
            verbatim: "nice explanation",
            kind: .quiet,
            createdAt: timestamp
        )
        let discuss = CommentRecord(
            pageIndex: 4,
            pageLabel: "5",
            verbatim: "The estimand is unclear here.",
            createdAt: timestamp.addingTimeInterval(1)
        )

        let markdown = MarkdownExporter.renderComments(
            title: "A Paper",
            highlights: [highlight],
            comments: [quiet, discuss]
        )

        XCTAssertTrue(markdown.contains("### Margin note `\(quiet.id.uuidString)`"))
        XCTAssertTrue(markdown.contains("nice explanation"))
        XCTAssertTrue(markdown.contains("### Comment `\(discuss.id.uuidString)`"))
        XCTAssertFalse(markdown.contains("### Comment `\(quiet.id.uuidString)`"))
    }

    func testMarkdownKeepsStableAnchorsAndSeparatesStandaloneComments() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let highlightID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let commentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let standaloneID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let highlight = HighlightRecord(
            id: highlightID,
            quote: "A claim with\n> Markdown",
            prefix: "",
            suffix: "",
            locations: [HighlightLocation(pageIndex: 6, pageLabel: "7", lineRects: [], textRanges: [])],
            createdAt: timestamp
        )
        let linked = CommentRecord(
            id: commentID,
            highlightID: highlightID,
            pageIndex: 6,
            pageLabel: "7",
            verbatim: "This implication needs clarification.",
            createdAt: timestamp
        )
        let standalone = CommentRecord(
            id: standaloneID,
            pageIndex: 8,
            pageLabel: "9",
            verbatim: "Return to the appendix.",
            createdAt: timestamp
        )

        let first = MarkdownExporter.renderComments(
            title: "A # Paper",
            highlights: [highlight],
            comments: [standalone, linked]
        )
        let second = MarkdownExporter.renderComments(
            title: "A # Paper",
            highlights: [highlight],
            comments: [standalone, linked]
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("Page 7 · Highlight `\(highlightID.uuidString)`"))
        XCTAssertTrue(first.contains("> A claim with\n> > Markdown"))
        XCTAssertTrue(first.contains("Comment `\(commentID.uuidString)`"))
        XCTAssertTrue(first.contains("## Standalone and orphaned comments"))
        XCTAssertTrue(first.contains("Comment `\(standaloneID.uuidString)` · Page 9"))
    }

    func testCurrentContextRoundTripsUnicodeAndReplacesStaleSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperCompanionContext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SessionPaths(root: root)
        let repository = SessionRepository()
        let sessionID = UUID()

        let first = CurrentContext(
            sessionID: sessionID,
            sourcePDFPath: "/tmp/Påper.pdf",
            sourcePDFFingerprint: "abc",
            pageIndex: 1,
            pageLabel: "2",
            selectedText: "A \"quoted\" line\nwith æøå and \\ slash",
            prefix: "før ",
            suffix: " efter",
            activeHighlightID: UUID(),
            textStatus: "selection",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.writeCurrentContext(first, paths: paths)

        let second = CurrentContext(
            sessionID: sessionID,
            sourcePDFPath: "/tmp/Påper.pdf",
            sourcePDFFingerprint: "abc",
            pageIndex: 4,
            pageLabel: "5",
            selectedText: nil,
            prefix: "bounded page excerpt",
            suffix: "",
            activeHighlightID: nil,
            textStatus: "page_excerpt",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try repository.writeCurrentContext(second, paths: paths)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CurrentContext.self, from: Data(contentsOf: paths.currentContextJSON))
        XCTAssertEqual(decoded, second)
        XCTAssertNil(decoded.selectedText)
        XCTAssertFalse(String(data: try Data(contentsOf: paths.currentContextJSON), encoding: .utf8)!.contains("quoted"))
    }

    func testDeletedHighlightsAreOmittedButLinkedCommentsRemainAuditable() {
        let id = UUID()
        let deleted = HighlightRecord(
            id: id,
            quote: "Removed highlight",
            prefix: "",
            suffix: "",
            locations: [HighlightLocation(pageIndex: 0, pageLabel: "1", lineRects: [], textRanges: [])],
            deletedAt: Date()
        )
        let comment = CommentRecord(highlightID: id, pageIndex: 0, pageLabel: "1", verbatim: "Preserved verbatim")
        let markdown = MarkdownExporter.renderComments(title: "Paper", highlights: [deleted], comments: [comment])
        XCTAssertFalse(markdown.contains("Removed highlight"))
        XCTAssertTrue(markdown.contains("Preserved verbatim"))
        XCTAssertTrue(markdown.contains("Original highlight `\(id.uuidString)` is no longer active"))
    }

    func testDeletedCommentsAreOmittedFromMarkdown() {
        let visible = CommentRecord(pageIndex: 0, pageLabel: "1", verbatim: "Keep this comment")
        let deleted = CommentRecord(
            pageIndex: 0,
            pageLabel: "1",
            verbatim: "Remove this comment",
            status: "deleted"
        )

        let markdown = MarkdownExporter.renderComments(
            title: "Paper",
            highlights: [],
            comments: [visible, deleted]
        )

        XCTAssertTrue(markdown.contains("Keep this comment"))
        XCTAssertFalse(markdown.contains("Remove this comment"))
    }
}
