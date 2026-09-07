import Foundation
import XCTest
@testable import PaperCompanionCore

final class ReadingOrderTests: XCTestCase {
    private func highlight(page: Int, offset: Int, createdAt: TimeInterval, quote: String) -> HighlightRecord {
        HighlightRecord(
            quote: quote,
            prefix: "",
            suffix: "",
            locations: [
                HighlightLocation(
                    pageIndex: page,
                    pageLabel: String(page + 1),
                    lineRects: [RectRecord(x: 0, y: 0, width: 10, height: 10)],
                    textRanges: [TextRangeRecord(location: offset, length: 5)]
                )
            ],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    func testEntriesFollowPaperOrderNotCreationOrder() {
        let late = highlight(page: 2, offset: 500, createdAt: 1, quote: "page three, made first")
        let middle = highlight(page: 0, offset: 200, createdAt: 2, quote: "page one, later in page")
        let early = highlight(page: 0, offset: 50, createdAt: 3, quote: "page one, earlier in page")
        let pageOnly = CommentRecord(pageIndex: 0, pageLabel: "1", verbatim: "page-level", createdAt: Date(timeIntervalSince1970: 4))
        let linked = CommentRecord(highlightID: middle.id, pageIndex: 0, pageLabel: "1", verbatim: "linked", createdAt: Date(timeIntervalSince1970: 5))

        let entries = AnnotationEntry.build(highlights: [late, middle, early], comments: [pageOnly, linked])

        XCTAssertEqual(entries.map(\.id), [pageOnly.id, early.id, middle.id, late.id])
        XCTAssertEqual(entries[2].comments.map(\.id), [linked.id])
        XCTAssertNil(entries[0].highlight)
    }

    func testOrphanedAndDeletedRecordsAreHandled() {
        var removed = highlight(page: 1, offset: 10, createdAt: 1, quote: "removed")
        let orphan = CommentRecord(highlightID: removed.id, pageIndex: 1, pageLabel: "2", verbatim: "orphan")
        removed.deletedAt = Date()
        let deletedComment = CommentRecord(pageIndex: 0, pageLabel: "1", verbatim: "gone", status: "deleted")
        let kept = highlight(page: 3, offset: 0, createdAt: 2, quote: "kept")

        let entries = AnnotationEntry.build(highlights: [removed, kept], comments: [orphan, deletedComment])

        XCTAssertEqual(entries.map(\.id), [orphan.id, kept.id])
        XCTAssertNil(entries[0].highlight)
        XCTAssertEqual(entries[0].pageLabel, "2")
    }

    func testHighlightWithoutTextRangesSortsAfterTextOnItsPage() {
        var geometryOnly = highlight(page: 0, offset: 0, createdAt: 1, quote: "geometry")
        geometryOnly.locations[0].textRanges = []
        let text = highlight(page: 0, offset: 900, createdAt: 2, quote: "text")

        let entries = AnnotationEntry.build(highlights: [geometryOnly, text], comments: [])

        XCTAssertEqual(entries.map(\.id), [text.id, geometryOnly.id])
    }
}
