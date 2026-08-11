import Foundation
import XCTest
@testable import PaperCompanionCore

final class SessionRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let repository = SessionRepository()

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperCompanionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSessionRoundTripPreservesHighlightsCommentsNotesAndSource() throws {
        let pdfURL = temporaryDirectory.appendingPathComponent("Danish paper ø.pdf")
        let originalBytes = Data("%PDF-1.4\nfixture\n%%EOF".utf8)
        try originalBytes.write(to: pdfURL)

        var loaded = try repository.createOrLoadSession(
            pdfURL: pdfURL,
            title: "Demokrati og vækst",
            pageCount: 2,
            extractedText: "--- Page 1 ---\nÆrlig text",
            sessionsRoot: temporaryDirectory.appendingPathComponent("Sessions")
        )
        let fixedDate = Date(timeIntervalSince1970: 100)
        let location = HighlightLocation(
            pageIndex: 1,
            pageLabel: "2",
            lineRects: [RectRecord(x: 10.25, y: 20.5, width: 100.75, height: 12)],
            textRanges: [TextRangeRecord(location: 30, length: 12)]
        )
        let highlight = HighlightRecord(
            quote: "Curly “quotes” and æøå",
            prefix: "Before ",
            suffix: " after",
            locations: [location],
            createdAt: fixedDate
        )
        let comment = CommentRecord(
            highlightID: highlight.id,
            pageIndex: 1,
            pageLabel: "2",
            verbatim: "First line\nSecond line with `code` and # heading",
            createdAt: fixedDate
        )
        loaded.highlights = [highlight]
        loaded.comments = [comment]
        loaded.notes = "# Mine noter\n\nBevar præcis ordlyd."
        try repository.saveState(
            manifest: loaded.manifest,
            highlights: loaded.highlights,
            comments: loaded.comments,
            notes: loaded.notes,
            paths: loaded.paths
        )

        let reloaded = try repository.loadSession(at: loaded.paths.root)
        XCTAssertEqual(reloaded.manifest.id, loaded.manifest.id)
        XCTAssertEqual(reloaded.manifest.title, loaded.manifest.title)
        XCTAssertEqual(reloaded.manifest.sourcePDFPath, loaded.manifest.sourcePDFPath)
        XCTAssertEqual(reloaded.manifest.sourcePDFFingerprint, loaded.manifest.sourcePDFFingerprint)
        XCTAssertEqual(reloaded.manifest.pageCount, loaded.manifest.pageCount)
        XCTAssertEqual(reloaded.highlights, [highlight])
        XCTAssertEqual(reloaded.comments, [comment])
        XCTAssertEqual(reloaded.notes, loaded.notes)
        XCTAssertEqual(try Data(contentsOf: pdfURL), originalBytes, "Session writes must not modify the PDF")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.paths.manifest.path + ".tmp"))
    }

    func testRepeatedCreateLoadsExistingSessionWithoutDuplicatingRecords() throws {
        let pdfURL = temporaryDirectory.appendingPathComponent("paper.pdf")
        try Data("stable source".utf8).write(to: pdfURL)
        let sessionsRoot = temporaryDirectory.appendingPathComponent("Sessions")

        var first = try repository.createOrLoadSession(
            pdfURL: pdfURL,
            title: "Paper",
            pageCount: 1,
            extractedText: "page text",
            sessionsRoot: sessionsRoot
        )
        let fixedDate = Date(timeIntervalSince1970: 100)
        let comment = CommentRecord(verbatim: "One comment", createdAt: fixedDate)
        first.comments = [comment]
        try repository.saveState(
            manifest: first.manifest,
            highlights: [],
            comments: first.comments,
            notes: first.notes,
            paths: first.paths
        )

        let second = try repository.createOrLoadSession(
            pdfURL: pdfURL,
            title: "Paper",
            pageCount: 1,
            extractedText: "different extraction should not overwrite existing session",
            sessionsRoot: sessionsRoot
        )
        XCTAssertEqual(second.manifest.id, first.manifest.id)
        XCTAssertEqual(second.comments, [comment])
    }

    func testMalformedManifestIsReportedWithoutOverwrite() throws {
        let root = temporaryDirectory.appendingPathComponent("Broken.reading")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("session.json")
        let malformed = Data("{broken".utf8)
        try malformed.write(to: manifest)

        XCTAssertThrowsError(try repository.loadSession(at: root))
        XCTAssertEqual(try Data(contentsOf: manifest), malformed)
    }
}
