import Foundation
import XCTest
@testable import PaperCompanion
import PaperCompanionCore

final class RecentPapersTests: XCTestCase {
    private func manifest(_ name: String, root: URL, updatedAt: Date = Date()) -> SessionManifest {
        SessionManifest(
            title: name,
            sourcePDFPath: root.appendingPathComponent("\(name).pdf").path,
            sourcePDFFingerprint: name,
            pageCount: 12,
            updatedAt: updatedAt
        )
    }

    @MainActor
    private func withFixture(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "PaperCompanion.RecentPapersTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try body(defaults, root)
    }

    private func writeSession(_ manifest: SessionManifest, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("session.json"))
    }

    @MainActor
    func testReopeningMovesPaperFirstAndPersistsUpdatedMetadataWithoutDuplicates() throws {
        try withFixture { defaults, root in
            let store = RecentPapersStore(defaults: defaults, sessionsRoot: root)
            var first = manifest("First", root: root)
            let second = manifest("Second", root: root)
            store.record(first)
            store.record(second)
            first.title = "Revised title"
            first.pageCount = 23
            store.record(first)

            XCTAssertEqual(store.papers.map(\.sourcePath), [first.sourcePDFPath, second.sourcePDFPath])
            XCTAssertEqual(store.papers.first?.title, "Revised title")
            XCTAssertEqual(store.papers.first?.pageCount, 23)
            let reopened = RecentPapersStore(defaults: defaults, sessionsRoot: root)
            XCTAssertEqual(reopened.papers, store.papers)
        }
    }

    @MainActor
    func testRemovalPersistsWithoutDeletingPDFOrSession() throws {
        try withFixture { defaults, root in
            let paper = manifest("Keep files", root: root)
            let pdf = URL(fileURLWithPath: paper.sourcePDFPath)
            let pdfData = Data("PDF fixture".utf8)
            try pdfData.write(to: pdf)
            let folder = root.appendingPathComponent("paper.reading")
            try writeSession(paper, folder: folder)
            let store = RecentPapersStore(defaults: defaults, sessionsRoot: root)
            store.remove(try XCTUnwrap(store.papers.first))

            XCTAssertTrue(store.papers.isEmpty)
            XCTAssertTrue(RecentPapersStore(defaults: defaults, sessionsRoot: root).papers.isEmpty)
            XCTAssertEqual(try Data(contentsOf: pdf), pdfData)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))
        }
    }

    @MainActor
    func testMigrationOrdersDeduplicatesAndIgnoresNestedOrMalformedSessionsOnlyOnce() throws {
        try withFixture { defaults, root in
            let old = manifest("Old", root: root, updatedAt: Date(timeIntervalSince1970: 100))
            var newest = old
            newest.title = "Most recent copy"
            newest.updatedAt = Date(timeIntervalSince1970: 300)
            let middle = manifest("Middle", root: root, updatedAt: Date(timeIntervalSince1970: 200))
            try writeSession(old, folder: root.appendingPathComponent("old.reading"))
            try writeSession(newest, folder: root.appendingPathComponent("new.reading"))
            try writeSession(middle, folder: root.appendingPathComponent("middle.reading"))
            try writeSession(manifest("Nested", root: root), folder: root.appendingPathComponent("archive/nested.reading"))
            let broken = root.appendingPathComponent("broken.reading")
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: broken.appendingPathComponent("session.json"))

            let store = RecentPapersStore(defaults: defaults, sessionsRoot: root)
            XCTAssertEqual(store.papers.map(\.title), ["Most recent copy", "Middle"])
            XCTAssertEqual(store.papers.first?.lastOpened, newest.updatedAt)
            try writeSession(manifest("Added later", root: root), folder: root.appendingPathComponent("later.reading"))
            XCTAssertEqual(RecentPapersStore(defaults: defaults, sessionsRoot: root).papers, store.papers)
        }
    }
}
