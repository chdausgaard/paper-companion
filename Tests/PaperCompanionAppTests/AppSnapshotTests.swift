import AppKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// Renders the screens outside the annotation list offscreen (an
/// NSHostingView in a window that is never shown; no screen capture) and
/// writes PNGs to the folder named by `PAPER_COMPANION_SNAPSHOT_DIR`: the
/// Library, the inspector's tab strip in each selection, the Notes tab and
/// the Agent tab, light and dark. Skipped when the variable is not set.
///
///     PAPER_COMPANION_SNAPSHOT_DIR=/tmp/snapshots swift test --filter AppSnapshot
final class AppSnapshotTests: XCTestCase {
    static let librarySize = NSSize(width: 900, height: 560)
    static let inspectorSize = NSSize(width: 420, height: 760)

    private var cleanups: [() -> Void] = []

    override func setUp() {
        super.setUp()
        // RegionTestSession sets auto-highlight, which AppState stores.
        restoreStandardDefaultsAfterTest()
        // The real pointer on this Mac must not decide the result.
        pinPointerStateForTest()
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for cleanup in cleanups { cleanup() }
            cleanups = []
        }
        super.tearDown()
    }

    @MainActor
    private func render<V: View>(
        _ name: String,
        size: NSSize,
        _ make: () throws -> (AppState, V),
        prepare: (AppState, NSView) -> Void = { _, _ in }
    ) throws {
        let directory = try SnapshotOutput.directory().appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let (state, view) = try make()
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let host = NSHostingView(rootView: view
                .environmentObject(state)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = appearance
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            spin(0.3)
            prepare(state, host)
            spin(0.5)
            host.layoutSubtreeIfNeeded()

            let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            let bytes = try SnapshotOutput.writePNG(of: host, appearance: appearance, to: url)
            XCTAssertGreaterThan(bytes, 8_000, "\(url.lastPathComponent) looks blank")
            window.contentView = nil
            window.close()
        }
    }

    // MARK: Library

    /// An isolated recent-papers list (its own defaults suite, its own
    /// folder): two papers whose PDFs exist and one whose PDF is gone.
    @MainActor
    private func library() throws -> (RecentPapersStore, [RecentPaper]) {
        let suite = "PaperCompanion.AppSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanups.append {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentPapersStore(defaults: defaults, sessionsRoot: root)
        let papers: [(String, Int, Bool)] = [
            ("Rollout timing and turnout: evidence from a staggered reform", 34, true),
            ("A moved paper whose PDF is no longer where it was", 18, false),
            ("Difference-in-differences with variation in treatment timing", 41, true),
        ]
        for (title, pages, exists) in papers.reversed() {
            let pdf = root.appendingPathComponent("\(title.prefix(20)).pdf")
            if exists { try Data("%PDF-1.4".utf8).write(to: pdf) }
            store.record(SessionManifest(title: title, sourcePDFPath: pdf.path, sourcePDFFingerprint: title, pageCount: pages))
        }
        return (store, store.papers)
    }

    @MainActor
    private func libraryView(_ store: RecentPapersStore, overrides: [String: PointerState] = [:]) -> some View {
        RecentPapersView(library: store, resumeReading: {}, openPaper: { _ in })
            .environment(\.pointerOverrides, overrides)
    }

    @MainActor
    func testSnapshotLibraryDefault() throws {
        try render("01-library", size: Self.librarySize) {
            let (store, _) = try library()
            return (AppState(), libraryView(store))
        }
    }

    @MainActor
    func testSnapshotLibraryRowHovered() throws {
        try render("02-library-row-hovered", size: Self.librarySize) {
            let (store, papers) = try library()
            return (AppState(), libraryView(store, overrides: [papers[0].id: .hovered]))
        }
    }

    @MainActor
    func testSnapshotLibraryRowPressed() throws {
        try render("03-library-row-pressed", size: Self.librarySize) {
            let (store, papers) = try library()
            return (AppState(), libraryView(store, overrides: [papers[0].id: .pressed]))
        }
    }

    /// The row whose PDF is missing, under the pointer: dimmed, no lift.
    @MainActor
    func testSnapshotLibraryMissingRowHovered() throws {
        try render("04-library-missing-hovered", size: Self.librarySize) {
            let (store, papers) = try library()
            return (AppState(), libraryView(store, overrides: [papers[1].id: .hovered]))
        }
    }

    // MARK: Inspector tab strip

    @MainActor
    private func inspector(_ tab: AppState.InspectorTab, overrides: [String: PointerState] = [:]) -> (AppState, some View) {
        let state = SidebarSnapshotTests.seed().state
        state.inspectorTab = tab
        return (state, InspectorView().environment(\.pointerOverrides, overrides))
    }

    @MainActor
    func testSnapshotTabStripAnnotations() throws {
        try render("05-tabs-annotations", size: Self.inspectorSize) { inspector(.annotations) }
    }

    @MainActor
    func testSnapshotTabStripNotesHovered() throws {
        try render("06-tabs-annotations-notes-hovered", size: Self.inspectorSize) {
            inspector(.annotations, overrides: [InspectorTabStrip.overrideKey(.notes): .hovered])
        }
    }

    @MainActor
    func testSnapshotTabStripAgentPressed() throws {
        try render("07-tabs-annotations-agent-pressed", size: Self.inspectorSize) {
            inspector(.annotations, overrides: [InspectorTabStrip.overrideKey(.agent): .pressed])
        }
    }

    // MARK: Notes

    @MainActor
    func testSnapshotNotesEmpty() throws {
        try render("08-notes-empty", size: Self.inspectorSize) { inspector(.notes) }
    }

    /// Notes with text, the box holding the keyboard: the focus ring.
    @MainActor
    func testSnapshotNotesFocused() throws {
        try render("09-notes-focused", size: Self.inspectorSize, {
            let (state, view) = inspector(.notes)
            state.notes = "Main worry: the pre-trends figure.\n\nCheck Appendix C for the Callaway–Sant’Anna estimates before the meeting."
            return (state, view)
        }, prepare: { _, host in
            if let notes = self.descendants(of: host, as: NotesTextView.self).first {
                host.window?.makeFirstResponder(notes)
            } else {
                XCTFail("no notes box")
            }
        })
    }

    // MARK: Agent

    /// A real session in a temporary folder, so the path, the reading-mode
    /// picker and the previews show as they do in the app.
    @MainActor
    private func agentSession() throws -> RegionTestSession {
        let session = try RegionTestSession()
        cleanups.append { session.remove() }
        return session
    }

    @MainActor
    private func agentInspector(overrides: [String: PointerState] = [:], session: RegionTestSession? = nil) throws -> (AppState, some View) {
        let state = try (session ?? agentSession()).state
        state.inspectorTab = .agent
        state.sharedUnderstandingPreview = """
        # Shared understanding

        ## Claim
        Early rollout raised turnout among first-time voters.

        ## Design
        Staggered adoption across municipalities, 2009–2015; synthetic control.
        """
        state.currentContextPreview = """
        # Current context
        Page 1 of 2 · reading mode: preread
        Active anchor: none
        """
        return (state, InspectorView().environment(\.pointerOverrides, overrides))
    }

    @MainActor
    func testSnapshotAgentTab() throws {
        try render("10-agent", size: Self.inspectorSize) { try agentInspector() }
    }

    /// The hovered path must differ from the idle one: the override has to
    /// reach the Agent tab through the inspector's own hosting views.
    @MainActor
    func testSnapshotAgentTabPathHovered() throws {
        try render("11-agent-path-hovered", size: Self.inspectorSize) {
            try agentInspector(overrides: [SessionPathButton.overrideKey: .hovered])
        }
        let session = try agentSession()
        func pixels(_ overrides: [String: PointerState]) throws -> Data {
            let (state, view) = try agentInspector(overrides: overrides, session: session)
            let host = NSHostingView(rootView: view.environmentObject(state)
                .frame(width: Self.inspectorSize.width, height: Self.inspectorSize.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: Self.inspectorSize)
            let appearance = NSAppearance(named: .aqua)!
            host.appearance = appearance
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            spin(0.5)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(SnapshotOutput.bitmap(of: host, appearance: appearance))
            window.contentView = nil
            window.close()
            return try XCTUnwrap(rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerPlane) })
        }
        let idle = try pixels([:])
        XCTAssertEqual(idle, try pixels([:]), "two idle renders are the same")
        XCTAssertNotEqual(idle, try pixels([SessionPathButton.overrideKey: .hovered]), "the hovered path draws differently")
    }

    /// The smallest inspector the window allows (680 pt of content less the
    /// status bar), both sections open by a real click, with long previews:
    /// everything stays inside the tab.
    @MainActor
    func testSnapshotAgentTabAtMinimumHeight() throws {
        let size = NSSize(width: 340, height: 655)
        try render("14-agent-minimum-height", size: size, {
            let (state, view) = try agentInspector()
            state.sharedUnderstandingPreview = (1...60).map { "Line \($0) of the agent's reading of the paper." }.joined(separator: "\n")
            state.currentContextPreview = (1...60).map { "Line \($0) of the current context." }.joined(separator: "\n")
            return (state, view)
        }, prepare: { _, host in
            guard let window = host.window else { return XCTFail("no window") }
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            guard let header = self.accessibilityNode(labeled: "Current context sent to the agent", under: host) else {
                return XCTFail("no header for the context section")
            }
            self.realClick(atWindowPoint: header.center, in: window, settle: 0.6)
            let nodes = self.accessibilityNodes(under: host).filter { $0.element !== host && !$0.frame.isEmpty }
            XCTAssertEqual(nodes.first { $0.label == "Current context sent to the agent" }?.value, "1", "the section opened")
            for node in nodes where node.label == "Reading mode" || node.label.hasPrefix("Current context") || node.label.hasPrefix("Agent’s reading") {
                XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(node.frame), "\(node.label) stays inside the tab: \(node.frame)")
            }
            // The previews' scroll views, the bottom one last: inside the tab.
            // (Their text runs past them by design; it scrolls.)
            let scrolls = self.descendants(of: host, as: NSScrollView.self)
            XCTAssertEqual(scrolls.count, 2, "both previews are open")
            for scroll in scrolls {
                let frame = scroll.convert(scroll.bounds, to: nil)
                XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "a preview stays inside the tab: \(frame)")
                XCTAssertGreaterThanOrEqual(frame.height, AgentPreviewPanel.minimumHeight - 1, "and keeps a few lines")
            }
        })
    }

    /// The second section opened by a real click on its header.
    @MainActor
    func testSnapshotAgentTabBothSectionsOpen() throws {
        try render("12-agent-both-open", size: Self.inspectorSize, { try agentInspector() }, prepare: { _, host in
            guard let window = host.window else { return XCTFail("no window") }
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            guard let header = self.accessibilityNode(labeled: "Current context sent to the agent", under: host) else {
                return XCTFail("no header for the context section")
            }
            self.realClick(atWindowPoint: header.center, in: window, settle: 0.5)
        })
    }

    // MARK: Status bar

    /// The inspector over the status bar, as the window's bottom right shows
    /// them, to judge the bar next to the new tab strip.
    @MainActor
    func testSnapshotStatusBarUnderInspector() throws {
        try render("13-status-bar", size: NSSize(width: 420, height: 300)) {
            let (state, _) = inspector(.notes)
            state.statusMessage = "Session path copied"
            state.document = TestPDF.make(pages: ["One page."])
            return (state, VStack(spacing: 0) {
                InspectorView()
                Divider()
                StatusBar()
            })
        }
    }
}
