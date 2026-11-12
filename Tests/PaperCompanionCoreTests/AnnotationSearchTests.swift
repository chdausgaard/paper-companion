import Foundation
import XCTest
@testable import PaperCompanionCore

final class AnnotationSearchTests: XCTestCase {
    private func highlight(page: Int, offset: Int, quote: String, label: String? = nil) -> HighlightRecord {
        HighlightRecord(
            quote: quote,
            prefix: "",
            suffix: "",
            locations: [
                HighlightLocation(
                    pageIndex: page,
                    pageLabel: label ?? String(page + 1),
                    lineRects: [RectRecord(x: 0, y: 0, width: 10, height: 10)],
                    textRanges: [TextRangeRecord(location: offset, length: 5)]
                )
            ]
        )
    }

    func testCardWithCommentsMatchesOnlyItsComments() {
        let marked = highlight(page: 0, offset: 10, quote: "Turnout rose sharply in rural districts")
        let comment = CommentRecord(highlightID: marked.id, pageIndex: 0, pageLabel: "1", verbatim: "Is this causal?")
        let entry = AnnotationEntry.build(highlights: [marked], comments: [comment])[0]

        XCTAssertTrue(AnnotationSearch.matches(entry, query: "causal"))
        XCTAssertFalse(AnnotationSearch.matches(entry, query: "turnout"), "the quote is not shown on a card with a comment")
    }

    func testHighlightWithoutCommentMatchesOnItsQuote() {
        let marked = highlight(page: 0, offset: 10, quote: "Turnout rose\nsharply in rural districts")
        let entry = AnnotationEntry.build(highlights: [marked], comments: [])[0]

        XCTAssertTrue(AnnotationSearch.matches(entry, query: "rose sharply"))
        XCTAssertEqual(entry.displayedTexts, ["Turnout rose sharply in rural districts"])
    }

    func testMatchingIsCaseAndDiacriticInsensitiveAndNeedsEveryTerm() {
        let page = CommentRecord(pageIndex: 2, pageLabel: "3", verbatim: "Café effects look naïve here")
        let entry = AnnotationEntry.build(highlights: [], comments: [page])[0]

        XCTAssertTrue(AnnotationSearch.matches(entry, query: "CAFE"))
        XCTAssertTrue(AnnotationSearch.matches(entry, query: "naive café"))
        XCTAssertTrue(AnnotationSearch.matches(entry, query: "  effects   "))
        XCTAssertFalse(AnnotationSearch.matches(entry, query: "naive bistro"), "every term must match")
        XCTAssertTrue(AnnotationSearch.matches(entry, query: "   "), "a blank query matches everything")
        XCTAssertFalse(AnnotationSearch.isActive(" \n "))
    }

    func testTermsMayMatchDifferentCommentsOfOneCard() {
        let marked = highlight(page: 0, offset: 10, quote: "quote")
        let first = CommentRecord(highlightID: marked.id, verbatim: "sample size", createdAt: Date(timeIntervalSince1970: 1))
        let second = CommentRecord(highlightID: marked.id, verbatim: "power analysis", createdAt: Date(timeIntervalSince1970: 2))
        let entries = AnnotationEntry.build(highlights: [marked], comments: [first, second])

        XCTAssertEqual(AnnotationSearch.filter(entries, query: "sample power").map(\.id), [marked.id])
        XCTAssertTrue(AnnotationSearch.filter(entries, query: "sample bias").isEmpty)
        XCTAssertEqual(AnnotationSearch.filter(entries, query: "").count, 1)
    }

    func testMatchRangesCoverEveryOccurrenceAndMergeOverlaps() {
        let text = "Élite elites and the ELITE"
        let ranges = AnnotationSearch.matchRanges(of: "elite", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Élite", "elite", "ELITE"])

        let overlapping = AnnotationSearch.matchRanges(of: "abc bcd", in: "xabcdx")
        XCTAssertEqual(overlapping.map { String("xabcdx"[$0]) }, ["abcd"])
        XCTAssertTrue(AnnotationSearch.matchRanges(of: "", in: text).isEmpty)
    }

    func testGroupingKeepsReadingOrderUnderOnePageHeaderEach() {
        let a = highlight(page: 0, offset: 10, quote: "a", label: "i")
        let b = highlight(page: 3, offset: 5, quote: "b", label: "4")
        let c = highlight(page: 3, offset: 50, quote: "c", label: "4")
        let pageNote = CommentRecord(pageIndex: 3, pageLabel: "4", verbatim: "page note")
        let entries = AnnotationEntry.build(highlights: [c, a, b], comments: [pageNote])

        let groups = AnnotationEntry.groupedByPage(entries)

        XCTAssertEqual(groups.map(\.pageIndex), [0, 3])
        XCTAssertEqual(groups.map(\.pageLabel), ["i", "4"])
        XCTAssertEqual(groups[1].entries.map(\.id), [pageNote.id, b.id, c.id])
        XCTAssertEqual(groups.flatMap(\.entries).map(\.id), entries.map(\.id))
    }

    func testGroupingUnsortedInputStillYieldsOneGroupPerPage() {
        let a = highlight(page: 1, offset: 10, quote: "a")
        let b = highlight(page: 0, offset: 10, quote: "b")
        let c = highlight(page: 1, offset: 90, quote: "c")
        let entries = [a, b, c].map { AnnotationEntry(id: $0.id, highlight: $0, comments: [], position: $0.readingPosition) }

        let groups = AnnotationEntry.groupedByPage(entries)

        XCTAssertEqual(groups.map(\.pageIndex), [1, 0])
        XCTAssertEqual(groups[0].entries.map(\.id), [a.id, c.id])
    }
}
