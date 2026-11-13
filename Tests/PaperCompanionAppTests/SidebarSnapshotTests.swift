import AppKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// Renders the sidebar offscreen (an NSHostingView in a window that is never
/// shown; no screen capture) and writes PNGs to the folder named by
/// `PAPER_COMPANION_SNAPSHOT_DIR`. Skipped when the variable is not set.
///
///     PAPER_COMPANION_SNAPSHOT_DIR=/tmp/snapshots swift test --filter Snapshot
final class SidebarSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The real pointer on this Mac must not decide the result.
        pinPointerStateForTest()
    }

    static let size = NSSize(width: 420, height: 760)

    struct Seed {
        let state: AppState
        let causal: HighlightRecord
        let replied: HighlightRecord
        let quoteOnly: HighlightRecord
        let marginNoted: HighlightRecord
        let pageComment: CommentRecord
    }

    private static func location(page: Int, label: String, offset: Int) -> HighlightLocation {
        HighlightLocation(
            pageIndex: page,
            pageLabel: label,
            lineRects: [RectRecord(x: 72, y: 600 - Double(offset), width: 300, height: 12)],
            textRanges: [TextRangeRecord(location: offset, length: 40)]
        )
    }

    /// One card of every kind: comments on yellow and blue highlights (the
    /// blue one with an agent reply), a page-level comment, a highlight with
    /// no comment, and a margin note.
    @MainActor
    static func seed() -> Seed {
        let state = AppState()
        let causal = HighlightRecord(
            quote: "Treated municipalities saw turnout rise relative to the synthetic control.",
            prefix: "", suffix: "",
            locations: [location(page: 3, label: "4", offset: 120)],
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let replied = HighlightRecord(
            quote: "We estimate the effect with two-way fixed effects.",
            prefix: "", suffix: "",
            locations: [location(page: 3, label: "4", offset: 900)],
            color: "blue",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let quoteOnly = HighlightRecord(
            quote: "Turnout among first-time voters rose by 4.2 percentage points in treated municipalities, against 1.1 points elsewhere.",
            prefix: "", suffix: "",
            locations: [location(page: 6, label: "7", offset: 300)],
            color: "green",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let marginNoted = HighlightRecord(
            quote: "The design exploits the staggered rollout.",
            prefix: "", suffix: "",
            locations: [location(page: 6, label: "7", offset: 800)],
            color: "pink",
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let pageComment = CommentRecord(
            pageIndex: 6, pageLabel: "7",
            verbatim: "The sampling frame on this page differs from the one in the abstract.",
            createdAt: Date(timeIntervalSince1970: 50)
        )
        let comments = [
            CommentRecord(highlightID: causal.id, pageIndex: 3, pageLabel: "4",
                          verbatim: "Is this effect causal, or does it pick up selection into treatment? The pre-trends figure is not convincing.",
                          createdAt: Date(timeIntervalSince1970: 11)),
            CommentRecord(highlightID: replied.id, pageIndex: 3, pageLabel: "4",
                          verbatim: "TWFE with staggered timing: are the effect sizes biased by forbidden comparisons?",
                          createdAt: Date(timeIntervalSince1970: 21)),
            pageComment,
            CommentRecord(highlightID: marginNoted.id, pageIndex: 6, pageLabel: "7",
                          verbatim: "nice explanation of the design",
                          kind: .quiet,
                          createdAt: Date(timeIntervalSince1970: 41)),
        ]
        state.highlights = [causal, replied, quoteOnly, marginNoted]
        state.comments = comments
        state.agentReplies = [
            comments[1].id: "Yes, with staggered adoption TWFE compares late adopters against early ones. The authors report **Callaway–Sant’Anna** estimates in Appendix C; they are close to the main ones.",
        ]
        state.currentPageIndex = 6
        state.currentPageLabel = "7"
        return Seed(state: state, causal: causal, replied: replied, quoteOnly: quoteOnly,
                    marginNoted: marginNoted, pageComment: pageComment)
    }

    /// The sidebar as the window shows it: the inspector with its tabs.
    @MainActor
    private func sidebar(_ state: AppState, overrides: [UUID: PointerState] = [:]) -> some View {
        InspectorView()
            .environmentObject(state)
            .environment(\.cardPointerOverrides, overrides)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @MainActor
    private func render<V: View>(_ name: String, _ make: () -> (AppState, V), prepare: (AppState) -> Void = { _ in }) throws {
        let directory = try SnapshotOutput.directory()
        for dark in [false, true] {
            let (state, view) = make()
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: Self.size)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            prepare(state)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()

            let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            let bytes = try SnapshotOutput.writePNG(of: host, appearance: appearance, to: url)
            XCTAssertGreaterThan(bytes, 10_000, "\(url.lastPathComponent) looks blank")
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    func testSnapshotDefaultListWithAllMarkers() throws {
        try render("01-default") {
            let seed = Self.seed()
            return (seed.state, sidebar(seed.state))
        }
    }

    @MainActor
    func testSnapshotHoveredCard() throws {
        try render("02-hovered") {
            let seed = Self.seed()
            return (seed.state, sidebar(seed.state, overrides: [seed.causal.id: .hovered]))
        }
    }

    @MainActor
    func testSnapshotPressedCard() throws {
        try render("03-pressed") {
            let seed = Self.seed()
            return (seed.state, sidebar(seed.state, overrides: [seed.pageComment.id: .pressed]))
        }
    }

    @MainActor
    func testSnapshotExpandedCardWithAgentReply() throws {
        try render("04-expanded-reply") {
            let seed = Self.seed()
            seed.state.selectedHighlightID = seed.replied.id
            return (seed.state, sidebar(seed.state))
        }
    }

    @MainActor
    func testSnapshotActiveSearch() throws {
        try render("05-search") {
            let seed = Self.seed()
            seed.state.annotationSearchQuery = "effect"
            return (seed.state, sidebar(seed.state))
        }
    }

    @MainActor
    func testSnapshotSearchWithoutMatches() throws {
        try render("06-search-no-match") {
            let seed = Self.seed()
            seed.state.annotationSearchQuery = "bootstrap"
            return (seed.state, sidebar(seed.state))
        }
    }

    @MainActor
    func testSnapshotEmpty() throws {
        try render("07-empty") {
            let state = AppState()
            return (state, sidebar(state))
        }
    }

    /// Page 7 alone, so the margin note is in view, with the quote-only card
    /// expanded to its full quote.
    @MainActor
    func testSnapshotMarginNoteAndExpandedQuote() throws {
        try render("09-margin-note-expanded-quote") {
            let seed = Self.seed()
            let pageFour: Set<UUID> = [seed.causal.id, seed.replied.id]
            seed.state.highlights.removeAll { pageFour.contains($0.id) }
            seed.state.comments.removeAll { $0.highlightID.map(pageFour.contains) ?? false }
            seed.state.selectedHighlightID = seed.quoteOnly.id
            return (seed.state, sidebar(seed.state))
        }
    }

    // MARK: Regions

    /// The seed plus three regions drawn on the figure paper with their real
    /// pictures in a temporary session: the chart with a comment and an
    /// agent reply, the note beside it with no comment (so its caption
    /// guess shows), and a box on page 2, where there is no caption.
    @MainActor
    private func regionSeed() throws -> (AppState, RegionTestSession, chart: HighlightRecord, side: HighlightRecord, bare: HighlightRecord) {
        let session = try RegionTestSession()
        regionSessions.append(session)
        let seed = Self.seed()
        let state = seed.state
        state.sessionPaths = session.paths
        func region(page index: Int, _ rect: CGRect, color: String, at seconds: TimeInterval) throws -> HighlightRecord {
            let page = try XCTUnwrap(session.document.page(at: index))
            let record = try XCTUnwrap(RegionSnapshot.makeRecord(page: page, rect: rect, color: color, createdAt: Date(timeIntervalSince1970: seconds)))
            try RegionSnapshot.writeImages(for: record, page: page, paths: session.paths)
            return record
        }
        let chart = try region(page: 0, FigurePDF.figure, color: "yellow", at: 1)
        let side = try region(page: 0, CGRect(x: 352, y: 190, width: 124, height: 92), color: "blue", at: 2)
        let bare = try region(page: 1, CGRect(x: 36, y: 330, width: 300, height: 56), color: "purple", at: 3)
        state.highlights = [chart, side, bare] + state.highlights
        let comment = CommentRecord(highlightID: chart.id, pageIndex: 0, pageLabel: "1",
                                    verbatim: "Is the 2015 bar the reform year? The text says the gap opened after the reform.",
                                    createdAt: Date(timeIntervalSince1970: 4))
        state.comments.append(comment)
        state.agentReplies[comment.id] = "The rollout started in 2009; the reform is the 2013 bar. The jump to 2015 is the first election after it."
        return (state, session, chart, side, bare)
    }

    private var regionSessions: [RegionTestSession] = []

    /// The pictures load off the main thread once the cards appear; the
    /// PNGs are taken after they arrived.
    @MainActor
    private func waitForRegionPictures(_ state: AppState) {
        spin(0.2)
        let deadline = Date().addingTimeInterval(5)
        while RegionImageCache.isLoading, Date() < deadline { spin(0.05) }
        XCTAssertFalse(RegionImageCache.isLoading, "the region pictures loaded")
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for session in regionSessions { session.remove() }
            regionSessions = []
        }
        super.tearDown()
    }

    @MainActor
    func testSnapshotRegionCards() throws {
        try render("10-region-cards", {
            let seed = try! regionSeed()
            return (seed.0, sidebar(seed.0))
        }, prepare: waitForRegionPictures)
    }

    /// The commented region expanded: its larger picture, the comment and
    /// the reply; the composer's chip names the region.
    @MainActor
    func testSnapshotRegionExpandedAndComposerChip() throws {
        try render("11-region-expanded-chip", {
            let seed = try! regionSeed()
            seed.0.selectedHighlightID = seed.chart.id
            return (seed.0, sidebar(seed.0))
        }, prepare: waitForRegionPictures)
    }

    /// A region with no comment expanded, hovered: its picture and caption.
    @MainActor
    func testSnapshotRegionWithoutCommentExpanded() throws {
        try render("12-region-no-comment-expanded", {
            let seed = try! regionSeed()
            seed.0.selectedHighlightID = seed.side.id
            return (seed.0, sidebar(seed.0, overrides: [seed.side.id: .hovered]))
        }, prepare: waitForRegionPictures)
    }

    /// A highlight just made with ⇧⌘H: the comment box has the keyboard and
    /// its chip names the new highlight.
    @MainActor
    func testSnapshotComposerFocusedAfterNewHighlight() throws {
        try render("08-new-highlight-focus", {
            let seed = Self.seed()
            seed.state.currentSelection = SelectionSnapshot(
                selectedText: "Effects are larger where the rollout came early in the electoral cycle.",
                prefix: "", suffix: "",
                locations: [Self.location(page: 6, label: "7", offset: 1200)]
            )
            return (seed.state, sidebar(seed.state))
        }, prepare: { state in
            state.addHighlight()
        })
    }
}
