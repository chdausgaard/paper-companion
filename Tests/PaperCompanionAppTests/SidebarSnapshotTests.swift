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

    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PAPER_COMPANION_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PAPER_COMPANION_SNAPSHOT_DIR to render sidebar snapshots")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        let directory = try outputDirectory()
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

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return XCTFail("No bitmap for \(name)")
            }
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 10_000, "\(url.lastPathComponent) looks blank")
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
