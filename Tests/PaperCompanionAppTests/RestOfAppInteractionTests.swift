import AppKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// Real clicks on the Library, the inspector's tab strip and the Agent tab:
/// mouse-down and mouse-up NSEvents through the window, in an offscreen
/// window that is ordered in. Controls are found through SwiftUI's own
/// accessibility tree, which also shows what each one announces.
final class RestOfAppInteractionTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func setUp() {
        super.setUp()
        // AppState stores auto-highlight in the standard defaults.
        restoreStandardDefaultsAfterTest()
        // The real pointer on this Mac must not decide the result.
        pinPointerStateForTest()
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for cleanup in cleanups.reversed() { cleanup() }
            cleanups = []
        }
        super.tearDown()
    }

    @MainActor
    private func host<V: View>(_ view: V, state: AppState, size: NSSize) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: view
            .environmentObject(state)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = offscreenWindow(for: hosting)
        cleanups.append { [weak self] in self?.closeOffscreenWindow(window) }
        spin()
        return (window, hosting)
    }

    @MainActor
    private func makeState() -> AppState {
        let state = AppState()
        state.autoHighlightEnabled = false
        return state
    }

    // MARK: Library

    /// A recent-papers list of its own (own defaults suite, own folder), so
    /// the user's list is never read or written.
    @MainActor
    private func isolatedLibrary(_ papers: [(title: String, exists: Bool)]) throws -> RecentPapersStore {
        let suite = "PaperCompanion.RestOfAppInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanups.append {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentPapersStore(defaults: defaults, sessionsRoot: root)
        for (index, paper) in papers.enumerated().reversed() {
            let pdf = root.appendingPathComponent("paper-\(index).pdf")
            if paper.exists { try Data("%PDF-1.4".utf8).write(to: pdf) }
            store.record(SessionManifest(title: paper.title, sourcePDFPath: pdf.path, sourcePDFFingerprint: paper.title, pageCount: 10 + index))
        }
        return store
    }

    @MainActor
    func testRealClicksAnywhereOnALibraryRowResumeThatPaper() throws {
        let store = try isolatedLibrary([
            ("Alpha paper on turnout", true),
            ("Bravo paper whose PDF moved", false),
            ("Charlie paper on timing", true),
        ])
        let papers = store.papers
        XCTAssertEqual(papers.map(\.title), ["Alpha paper on turnout", "Bravo paper whose PDF moved", "Charlie paper on timing"])
        let state = makeState()
        var opened: [URL] = []
        let (window, root) = host(
            RecentPapersView(library: store, resumeReading: nil, openPaper: { opened.append($0) }),
            state: state, size: NSSize(width: 900, height: 600))

        // Each row is one element named after its paper, with its details.
        let nodes = accessibilityNodes(under: root)
        let rows = try papers.map { paper in
            try XCTUnwrap(nodes.first { $0.label.hasPrefix(paper.title + ", ") }, "a row for \(paper.title)")
        }
        XCTAssertTrue(rows[0].label.hasPrefix("Alpha paper on turnout, 10 pages, opened"), "the row announces its details: \(rows[0].label)")
        XCTAssertTrue(rows[1].label.hasSuffix("file unavailable"), "the missing PDF is announced: \(rows[1].label)")
        XCTAssertFalse(nodes.contains { $0.label.hasPrefix("Remove ") }, "the remove controls are hidden at rest")
        XCTAssertGreaterThan(rows[2].frame.width, 700, "the row spans the list: \(rows[2].frame)")

        // Everywhere on the third row, from its rounded corner's inside edge to
        // the chevron, short of the remove control at the far right.
        let row = rows[2].frame
        let points: [(String, NSPoint)] = [
            ("left padding", NSPoint(x: row.minX + 5, y: row.midY)),
            ("document icon", NSPoint(x: row.minX + 30, y: row.midY)),
            ("title", NSPoint(x: row.minX + 120, y: row.maxY - 22)),
            ("path line", NSPoint(x: row.minX + 300, y: row.midY)),
            ("top padding", NSPoint(x: row.midX, y: row.maxY - 4)),
            ("bottom padding", NSPoint(x: row.minX + 200, y: row.minY + 4)),
            ("blank space before the chevron", NSPoint(x: row.maxX - 120, y: row.midY)),
            ("chevron", NSPoint(x: row.maxX - 62, y: row.midY)),
        ]
        let charlie = URL(fileURLWithPath: papers[2].sourcePath)
        for (name, point) in points {
            let before = opened.count
            realClick(atWindowPoint: point, in: window, settle: 0.15)
            XCTAssertEqual(opened.count, before + 1, "a click on the \(name) opens a paper")
            XCTAssertEqual(opened.last, charlie, "a click on the \(name) resumes that row's paper")
        }

        realClick(atWindowPoint: rows[0].center, in: window, settle: 0.15)
        XCTAssertEqual(opened.last, URL(fileURLWithPath: papers[0].sourcePath), "the first row resumes the first paper")

        // A row whose PDF is gone does not open; it explains.
        let count = opened.count
        realClick(atWindowPoint: rows[1].center, in: window, settle: 0.15)
        XCTAssertEqual(opened.count, count, "a missing PDF is not opened")
        XCTAssertNotNil(state.errorMessage, "and the user is told how to find it")
        state.errorMessage = nil

        // The remove control takes its own click, after the pointer arrived on
        // the row (it fades in on hover), and the row does not also open.
        let removePoint = NSPoint(x: rows[0].frame.maxX - 23, y: rows[0].frame.midY)
        let tracker = try hoverTracker(at: removePoint, in: window)
        pointer(.mouseEntered, atWindowPoint: removePoint, trackedBy: tracker)
        pointer(.mouseMoved, atWindowPoint: removePoint, trackedBy: tracker)
        var shown: AccessibilityNode?
        waitForHover(redeliver: { pointer(.mouseMoved, atWindowPoint: removePoint, trackedBy: tracker) }) {
            shown = accessibilityNode(labeled: "Remove \(papers[0].title) from recent papers", under: root)
            return shown != nil
        }
        let remove = try XCTUnwrap(shown, "the remove control showed on hover")
        XCTAssertTrue(remove.frame.contains(removePoint), "it sits at the row's end: \(remove.frame)")
        realClick(atWindowPoint: remove.center, in: window)
        XCTAssertEqual(store.papers.map(\.title), ["Bravo paper whose PDF moved", "Charlie paper on timing"], "the remove control removed its paper")
        XCTAssertEqual(opened.count, count, "and did not open it")
    }

    /// The row's remove action is also offered to VoiceOver and keyboard
    /// users without the pointer: as a named accessibility action.
    @MainActor
    func testLibraryRowOffersRemoveAsAnAccessibilityAction() throws {
        let store = try isolatedLibrary([("Delta paper", true)])
        let (_, root) = host(RecentPapersView(library: store, resumeReading: nil, openPaper: { _ in }),
                             state: makeState(), size: NSSize(width: 900, height: 400))
        let row = try XCTUnwrap(accessibilityNodes(under: root).first { $0.label.hasPrefix("Delta paper, ") })
        let actions = (row.element.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
        let remove = try XCTUnwrap(actions.first { $0.name == "Remove from Recent Papers" }, "actions: \(actions.map(\.name))")
        if let handler = remove.handler {
            _ = handler()
        } else if let target = remove.target as? NSObject, let selector = remove.selector {
            _ = target.perform(selector, with: remove)
        }
        spin(0.1)
        XCTAssertTrue(store.papers.isEmpty)
    }

    /// The view the hover of a point is tracked by: the nearest ancestor of
    /// the hit view that owns a mouse-moved tracking area.
    @MainActor
    private func hoverTracker(at point: NSPoint, in window: NSWindow) throws -> NSView {
        var view = hitView(atWindowPoint: point, in: window)
        while let current = view, !current.trackingAreas.contains(where: { $0.owner === current && $0.options.contains(.mouseMoved) }) {
            view = current.superview
        }
        return try XCTUnwrap(view, "no hover tracking above \(point)")
    }

    // MARK: Inspector tab strip

    /// The seeded sidebar plus twenty page comments, so the list scrolls.
    @MainActor
    private func longSeed() -> AppState {
        let state = SidebarSnapshotTests.seed().state
        state.autoHighlightEnabled = false
        for index in 0..<20 {
            state.comments.append(CommentRecord(
                pageIndex: 9, pageLabel: "10",
                verbatim: "Filler comment \(index) about the robustness section, long enough to wrap onto a second line.",
                createdAt: Date(timeIntervalSince1970: 100 + Double(index))))
        }
        return state
    }

    @MainActor
    private func tab(_ title: String, under root: NSView) throws -> AccessibilityNode {
        // The strip is the top 50 points of the inspector.
        let strip = NSRect(x: root.frame.minX, y: root.frame.maxY - 50, width: root.frame.width, height: 50)
        return try XCTUnwrap(accessibilityNode(labeled: title, under: root, in: strip), "a \(title) tab in the strip")
    }

    @MainActor
    func testRealClicksOnEachTabSelectIt() throws {
        let state = longSeed()
        state.inspectorTab = .annotations
        let (window, root) = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))

        for (title, expected) in [("Notes", AppState.InspectorTab.notes), ("Agent", .agent), ("Annotations", .annotations), ("Agent", .agent)] {
            let node = try tab(title, under: root)
            // On the label, and on the tab's blank edge.
            for point in [node.center, NSPoint(x: node.frame.minX + 4, y: node.frame.minY + 4)] {
                state.inspectorTab = expected == .annotations ? .notes : .annotations
                spin(0.1)
                realClick(atWindowPoint: point, in: window, settle: 0.2)
                XCTAssertEqual(state.inspectorTab, expected, "a click on the \(title) tab at \(point) selects it")
            }
        }

        // What the strip announces: the selected tab carries the selected trait.
        state.inspectorTab = .notes
        spin(0.2)
        let notes = try tab("Notes", under: root)
        let agent = try tab("Agent", under: root)
        XCTAssertEqual(notes.element.value(forKey: "accessibilitySelected") as? Bool, true, "Notes is announced as selected")
        XCTAssertNotEqual(agent.element.value(forKey: "accessibilitySelected") as? Bool, true, "Agent is not")
    }

    /// ← and → move the selection while the strip has the keyboard: real
    /// key events through a key-capable window to the strip's key view. The
    /// view is made first responder directly; reaching it with Tab needs full
    /// keyboard access, a system setting the test does not change.
    @MainActor
    func testArrowKeysMoveBetweenTabsWhenTheStripHasTheKeyboard() throws {
        let state = longSeed()
        state.inspectorTab = .annotations
        let hosting = NSHostingView(rootView: InspectorView().environmentObject(state).frame(width: 420, height: 760))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        // Borderless and far off screen, but able to become key, as the
        // region test's window (RegionWorkflowTests.swift).
        let window = KeyableTestWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        window.makeKey()
        XCTAssertLessThan(window.frame.maxX, 0, "the test window stays off screen")
        cleanups.append { [weak self] in self?.closeOffscreenWindow(window) }
        spin()
        let keys = try XCTUnwrap(descendants(of: hosting, as: TabStripKeyView.self).first)
        XCTAssertNil(hitView(atWindowPoint: keys.convert(NSPoint(x: keys.bounds.midX, y: keys.bounds.midY), to: nil), in: window)
            .flatMap { $0 as? TabStripKeyView }, "clicks pass through to the tabs")
        XCTAssertTrue(window.makeFirstResponder(keys))

        func press(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            dispatchThroughQueue([event])
        }
        let right = "\u{F703}", left = "\u{F702}"
        press(124, right)
        XCTAssertEqual(state.inspectorTab, .notes, "→ selects the next tab")
        press(124, right)
        XCTAssertEqual(state.inspectorTab, .agent)
        press(124, right)
        XCTAssertEqual(state.inspectorTab, .agent, "the last tab stays")
        press(123, left)
        XCTAssertEqual(state.inspectorTab, .notes, "← selects the previous tab")
        press(123, left, modifiers: [.command])
        XCTAssertEqual(state.inspectorTab, .notes, "⌘← is not a tab move")
        press(123, left)
        press(123, left)
        XCTAssertEqual(state.inspectorTab, .annotations, "the first tab stays")
        XCTAssertTrue(window.firstResponder === keys, "the strip keeps the keyboard while the content changes under it")
    }

    /// Only the shown tab's content is in the window: a hidden tab takes no
    /// keys and no focus. Code that sets `inspectorTab` switches the content.
    @MainActor
    func testOnlyTheSelectedTabIsInTheWindowAndOtherCodeCanSwitchIt() throws {
        let state = longSeed()
        state.document = TestPDF.make(pages: ["One page."])
        state.inspectorTab = .notes
        let (_, root) = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))
        XCTAssertEqual(descendants(of: root, as: NotesTextView.self).count, 1)
        XCTAssertTrue(descendants(of: root, as: CommentTextView.self).isEmpty, "the comment box is not in the window")
        XCTAssertTrue(descendants(of: root, as: EscapeKeyMonitor.MonitorView.self).isEmpty, "nor the list's Esc monitor")

        state.findInComments()
        spin(0.5)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertEqual(descendants(of: root, as: CommentTextView.self).count, 1)
        XCTAssertTrue(descendants(of: root, as: NotesTextView.self).isEmpty)
        let field = try XCTUnwrap(descendants(of: root, as: WindowAwareSearchField.self).first)
        let editor = try XCTUnwrap(root.window?.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === field, "the search field took the keyboard")
    }

    // MARK: Requests that arrive before the Annotations page exists

    /// The inspector as it is after returning from the Library with Notes
    /// showing: its Annotations page has never been made.
    @MainActor
    private func inspectorWithoutAnnotationsPage(_ state: AppState, tab: AppState.InspectorTab = .notes) -> (NSWindow, NSView) {
        state.inspectorTab = tab
        let hosted = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))
        let pages = descendants(of: hosted.1, as: InspectorPagesView.self).first
        XCTAssertNil(pages?.pages[.annotations], "the Annotations page has not been made")
        XCTAssertTrue(descendants(of: hosted.1, as: CommentTextView.self).isEmpty)
        return hosted
    }

    /// The seed plus a commented highlight at the end of the long list, so
    /// revealing it needs a scroll.
    @MainActor
    private func seedWithLastHighlight() -> (AppState, HighlightRecord) {
        let state = longSeed()
        let last = HighlightRecord(
            quote: "The last highlighted passage of the paper", prefix: "", suffix: "",
            locations: [HighlightLocation(pageIndex: 30, pageLabel: "31",
                                          lineRects: [RectRecord(x: 72, y: 300, width: 300, height: 12)],
                                          textRanges: [TextRangeRecord(location: 10, length: 40)])],
            createdAt: Date(timeIntervalSince1970: 500))
        state.highlights.append(last)
        state.comments.append(CommentRecord(highlightID: last.id, pageIndex: 30, pageLabel: "31",
                                            verbatim: "Comment on the last highlight", createdAt: Date(timeIntervalSince1970: 501)))
        return (state, last)
    }

    @MainActor
    private func listScrollOffset(_ root: NSView) throws -> CGFloat {
        let list = try XCTUnwrap(descendants(of: root, as: NSScrollView.self).first {
            $0.documentView != nil && !($0.documentView is NSTextView) && !$0.isHiddenOrHasHiddenAncestor
        }, "the list is in the window")
        return list.contentView.bounds.origin.y
    }

    /// A highlight clicked in the PDF while the Annotations page has never
    /// been made: the tab switches and its card is scrolled into view.
    @MainActor
    func testRevealReachesAnAnnotationsPageNotYetMade() throws {
        let (state, last) = seedWithLastHighlight()
        let (_, root) = inspectorWithoutAnnotationsPage(state)
        state.highlightClicked(last.id)
        spin(0.8)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertGreaterThan(try listScrollOffset(root), 200, "the list scrolled to the clicked highlight's card")
    }

    /// The same with a page that exists but is hidden.
    @MainActor
    func testRevealReachesAHiddenAnnotationsPage() throws {
        let (state, last) = seedWithLastHighlight()
        state.inspectorTab = .annotations
        let (_, root) = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))
        XCTAssertEqual(try listScrollOffset(root), 0)
        state.inspectorTab = .agent
        spin(0.3)
        state.highlightClicked(last.id)
        spin(0.8)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertGreaterThan(try listScrollOffset(root), 200, "the list scrolled to the clicked highlight's card")
    }

    /// A new highlight while the Annotations page has never been made: the
    /// comment box is made and takes the keyboard.
    @MainActor
    func testCommentFocusReachesAnAnnotationsPageNotYetMade() throws {
        let state = longSeed()
        let (window, _) = inspectorWithoutAnnotationsPage(state, tab: .agent)
        state.currentSelection = SelectionSnapshot(
            selectedText: "A passage selected in the PDF", prefix: "", suffix: "",
            locations: [HighlightLocation(pageIndex: 2, pageLabel: "3",
                                          lineRects: [RectRecord(x: 72, y: 300, width: 300, height: 12)],
                                          textRanges: [TextRangeRecord(location: 10, length: 29)])])
        state.addHighlight()
        spin(0.6)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertTrue(window.firstResponder is CommentTextView, "the comment box has the keyboard")
    }

    /// Find in Comments while the Annotations page has never been made.
    @MainActor
    func testFindInCommentsReachesAnAnnotationsPageNotYetMade() throws {
        let state = longSeed()
        state.document = TestPDF.make(pages: ["One page."])
        let (window, root) = inspectorWithoutAnnotationsPage(state, tab: .agent)
        state.findInComments()
        spin(0.6)
        XCTAssertEqual(state.inspectorTab, .annotations)
        let field = try XCTUnwrap(descendants(of: root, as: WindowAwareSearchField.self).first)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === field, "the search field has the keyboard")
    }

    /// The comment draft, the search text, the list's scroll position, the
    /// notes and the Agent tab's open section all survive switching tabs by
    /// real clicks, in the same views; a change made while a tab is hidden
    /// shows when it returns.
    @MainActor
    func testTabContentsKeepTheirStateAcrossRealTabSwitches() throws {
        let state = longSeed()
        state.inspectorTab = .annotations
        let (window, root) = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))

        let composer = try XCTUnwrap(descendants(of: root, as: CommentTextView.self).first)
        window.makeFirstResponder(composer)
        composer.insertText("A half-written comment", replacementRange: composer.selectedRange())
        let field = try XCTUnwrap(descendants(of: root, as: WindowAwareSearchField.self).first)
        window.makeFirstResponder(field)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.insertText("comment", replacementRange: fieldEditor.selectedRange())
        XCTAssertEqual(state.annotationSearchQuery, "comment")
        window.makeFirstResponder(nil)
        spin(0.2)

        let list = try XCTUnwrap(descendants(of: root, as: NSScrollView.self).first {
            $0.documentView != nil && !($0.documentView is NSTextView)
        })
        let documentHeight = try XCTUnwrap(list.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, list.contentView.bounds.height + 300, "the list scrolls")
        list.contentView.scroll(to: NSPoint(x: 0, y: 300))
        list.reflectScrolledClipView(list.contentView)
        spin(0.2)
        let scrolled = list.contentView.bounds.origin
        XCTAssertEqual(scrolled.y, 300, accuracy: 1)

        // To Notes: type there.
        realClick(atWindowPoint: try tab("Notes", under: root).center, in: window)
        XCTAssertEqual(state.inspectorTab, .notes)
        XCTAssertNil(composer.window, "the hidden comment box left the window")
        let notes = try XCTUnwrap(descendants(of: root, as: NotesTextView.self).first)
        window.makeFirstResponder(notes)
        notes.insertText("Notes typed in the tab", replacementRange: notes.selectedRange())
        XCTAssertEqual(state.notes, "Notes typed in the tab")

        // To Agent: open the second section with a real click on its header.
        realClick(atWindowPoint: try tab("Agent", under: root).center, in: window)
        XCTAssertEqual(state.inspectorTab, .agent)
        let header = try XCTUnwrap(accessibilityNode(labeled: "Current context sent to the agent", under: root))
        XCTAssertEqual(header.value, "0", "announced as collapsed")
        realClick(atWindowPoint: header.center, in: window, settle: 0.5)
        XCTAssertEqual(accessibilityNode(labeled: "Current context sent to the agent", under: root)?.value, "1", "announced as expanded")

        // A comment saved elsewhere while the list is hidden, at the end of
        // the list so the scroll position can be compared.
        state.comments.append(CommentRecord(pageIndex: 30, pageLabel: "31", verbatim: "Added while hidden, a comment",
                                            createdAt: Date(timeIntervalSince1970: 1)))

        // Back to Annotations: the same views, as they were.
        realClick(atWindowPoint: try tab("Annotations", under: root).center, in: window)
        XCTAssertEqual(state.inspectorTab, .annotations)
        XCTAssertTrue(descendants(of: root, as: CommentTextView.self).first === composer, "the same comment box")
        XCTAssertEqual(composer.string, "A half-written comment", "the draft survived")
        XCTAssertTrue(descendants(of: root, as: WindowAwareSearchField.self).first === field, "the same search field")
        XCTAssertEqual(field.stringValue, "comment", "the search text survived")
        XCTAssertEqual(state.annotationSearchQuery, "comment")
        let listAgain = try XCTUnwrap(descendants(of: root, as: NSScrollView.self).first {
            $0.documentView != nil && !($0.documentView is NSTextView)
        })
        XCTAssertTrue(listAgain === list, "the same list")
        XCTAssertEqual(list.contentView.bounds.origin.y, scrolled.y, accuracy: 1, "the scroll position survived")
        list.contentView.scroll(to: NSPoint(x: 0, y: try XCTUnwrap(list.documentView).frame.height - list.contentView.bounds.height))
        list.reflectScrolledClipView(list.contentView)
        spin(0.3)
        XCTAssertNotNil(accessibilityNode(labeled: "Added while hidden, a comment", under: root)
            ?? accessibilityNodes(under: root).first { $0.label.contains("Added while hidden") },
            "the comment added while the list was hidden shows")

        // Back to Notes and Agent: the same notes box with its text; the
        // section still open.
        realClick(atWindowPoint: try tab("Notes", under: root).center, in: window)
        XCTAssertTrue(descendants(of: root, as: NotesTextView.self).first === notes, "the same notes box")
        XCTAssertEqual(notes.string, "Notes typed in the tab")
        realClick(atWindowPoint: try tab("Agent", under: root).center, in: window)
        XCTAssertEqual(accessibilityNode(labeled: "Current context sent to the agent", under: root)?.value, "1",
                       "the open section stayed open")
    }

    // MARK: Notes

    @MainActor
    func testNotesBoxEditsTheNotesAndEscDoesNothing() throws {
        let state = makeState()
        state.inspectorTab = .notes
        let (window, root) = host(InspectorView(), state: state, size: NSSize(width: 420, height: 760))
        let notes = try XCTUnwrap(descendants(of: root, as: NotesTextView.self).first)
        XCTAssertEqual(notes.accessibilityLabel(), "Document notes")

        // A real click in the box puts the keyboard there.
        let box = notes.convert(notes.bounds, to: nil)
        realClick(atWindowPoint: NSPoint(x: box.midX, y: box.maxY - 40), in: window)
        XCTAssertTrue(window.firstResponder === notes, "a click puts the keyboard in the notes")
        notes.insertText("First line", replacementRange: notes.selectedRange())
        XCTAssertEqual(state.notes, "First line")

        notes.keyDown(with: keyDown(53, characters: "\u{1b}", in: window))
        spin(0.1)
        XCTAssertTrue(window.firstResponder === notes, "Esc leaves the keyboard in the notes")
        XCTAssertEqual(state.notes, "First line")

        state.notes = "Replaced from outside"
        spin(0.1)
        XCTAssertEqual(notes.string, "Replaced from outside", "the box follows the notes")
    }

    // MARK: Agent tab

    @MainActor
    func testRealClickOnTheSessionPathCopiesIt() throws {
        let session = try RegionTestSession()
        cleanups.append { session.remove() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PaperCompanionTests-\(UUID().uuidString)"))
        cleanups.append { pasteboard.releaseGlobally() }
        let general = NSPasteboard.general.changeCount
        let state = session.state
        let (window, root) = host(AgentContextView(pasteboard: pasteboard), state: state, size: NSSize(width: 420, height: 760))

        let path = try XCTUnwrap(accessibilityNode(labeled: "Session folder", under: root))
        XCTAssertEqual(path.value, session.paths.root.path, "the path is announced")
        realClick(atWindowPoint: path.center, in: window)

        XCTAssertEqual(pasteboard.string(forType: .string), session.paths.root.path, "the click copied the path")
        XCTAssertEqual(state.statusMessage, "Session path copied", "and said so in the status bar")
        XCTAssertEqual(NSPasteboard.general.changeCount, general, "the user's clipboard was left alone")
    }
}
