import PaperCompanionCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var updates: AppUpdates
    @Environment(\.openWindow) private var openWindow
    @State private var showLibrary = false

    var body: some View {
        // The status bar is a row of the window, not a safe-area inset: as an
        // inset it floated over the PDF and clipped the last line of the page.
        VStack(spacing: 0) {
            Group {
                if state.document == nil || showLibrary {
                    RecentPapersView(
                        library: state.recentPapers,
                        resumeReading: state.document == nil ? nil : { showLibrary = false }
                    )
                } else {
                    HSplitView {
                        PDFReaderView(state: state)
                            .frame(minWidth: 560, minHeight: 560)

                        InspectorView()
                            .frame(minWidth: 340, idealWidth: 420, maxWidth: 640)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBar()
        }
        .frame(minWidth: 980, minHeight: 680)
        .onChange(of: state.document) { _ in showLibrary = false }
        .task { await updates.start() }
        .sheet(item: $updates.notice, onDismiss: updates.noticeDismissed) { notice in
            UpdateNoticeView(notice: notice)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showLibrary.toggle()
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .help("Show recent papers")

                Button {
                    state.openPDF()
                } label: {
                    Label("Open PDF", systemImage: "doc")
                }
                .help("Open a PDF (⌘O)")

                Button {
                    state.addHighlight()
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }
                .disabled(state.currentSelection == nil)
                .help("Highlight the selected PDF text (⇧⌘H)")

                Toggle(isOn: $state.regionToolActive) {
                    Label("Comment on Region", systemImage: "rectangle.dashed")
                }
                .toggleStyle(.button)
                // Not while the library shows: there is no page to draw on.
                .disabled(!state.canUseRegionTool)
                .help("Drag a box over a figure, table or any area of a page to comment on it (⇧⌘R). Esc cancels.")

                Toggle(isOn: $state.autoHighlightEnabled) {
                    Label("Auto Highlight", systemImage: "cursorarrow.motionlines")
                }
                .toggleStyle(.button)
                .disabled(state.document == nil)
                .help("Auto-highlight after each text selection. Search matches are never auto-highlighted.")

                Button {
                    openWindow(id: "notes")
                } label: {
                    Label("Notes Window", systemImage: "rectangle.on.rectangle")
                }
                .disabled(state.document == nil)
                .help("Open the comment composer and document notes in a separate window")
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    TextField("Search paper", text: $state.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { state.requestSearch() }
                    Button(action: state.requestSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Find next match")
                }
            }

            ToolbarItemGroup {
                Button(action: updates.requestFeature) {
                    Label("Request Feature", systemImage: "lightbulb")
                }
                .help("Suggest an improvement to Paper Companion")

                Button(action: state.copyAgentPrompt) {
                    Label("Copy Agent Prompt", systemImage: "quote.bubble")
                }
                .disabled(state.sessionPaths == nil)
                .help("Copy a prompt that points an external agent to this reading session")

                Button(action: state.revealSessionFolder) {
                    Label("Reveal Session", systemImage: "folder")
                }
                .disabled(state.sessionPaths == nil)
                .help("Reveal this paper’s notes, comments, highlights, and agent files in Finder")
            }
        }
        .alert("Paper Companion", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "Unknown error")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            Text(state.statusMessage)
                .lineLimit(1)
            Spacer()
            if state.document != nil {
                if state.readingMode == .together {
                    Label("Together", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                        .help("Discover-together mode: the agent reads only what you have reached")
                }
                if state.autoHighlightEnabled {
                    Label("Auto-highlight on", systemImage: "cursorarrow.motionlines")
                        .foregroundStyle(.secondary)
                }
                Text("Page \(state.currentPageLabel)")
                    .foregroundStyle(.secondary)
                if let selection = state.currentSelection {
                    Text("· \(selection.selectedText.count) selected characters")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 24)
        .background(.bar)
    }
}

/// The inspector: a compact tab strip over the selected tab's content. Each
/// tab's content lives as long as the inspector, so the comment draft, the
/// notes, the search text and every scroll position survive a tab switch.
struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.cardPointerOverrides) private var cardPointerOverrides
    @Environment(\.pointerOverrides) private var pointerOverrides

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabStrip(selection: $state.inspectorTab)
            Divider()
            InspectorPages(
                selection: state.inspectorTab,
                state: state,
                environment: .init(cardPointerOverrides: cardPointerOverrides, pointerOverrides: pointerOverrides)
            )
                // The tint the old tab box gave its content, which the list's
                // pinned page headers repeat so they do not read as bands.
                .background(
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        Color.primary.opacity(0.03)
                    }
                )
        }
    }
}

/// Annotations, Notes and Agent as one strip: each tab answers hover and
/// press like the cards below it, and the selected one sits on a lifted mark
/// that slides to the new tab (a fade with Reduce Motion). For the keyboard
/// the strip is one stop, as the system's tab view is: ← and → move the
/// selection (`TabStripKeyView`). VoiceOver reads each tab as a button that
/// is selected or not.
struct InspectorTabStrip: View {
    @Binding var selection: AppState.InspectorTab
    @Namespace private var markSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Tab: Identifiable {
        let id: AppState.InspectorTab
        let title: String
        let systemImage: String
    }

    static let tabs = [
        Tab(id: .annotations, title: "Annotations", systemImage: "highlighter"),
        Tab(id: .notes, title: "Notes", systemImage: "square.and.pencil"),
        Tab(id: .agent, title: "Agent", systemImage: "sparkles"),
    ]

    /// The tab `step` places to the left (-1) or right (+1); the ends stop.
    private func move(_ step: Int) {
        let ids = Self.tabs.map(\.id)
        guard let index = ids.firstIndex(of: selection) else { return }
        let next = index + step
        guard ids.indices.contains(next) else { return }
        selection = ids[next]
    }

    /// A tab's key in `pointerOverrides`.
    static func overrideKey(_ tab: AppState.InspectorTab) -> String { "inspector-tab.\(tab)" }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs) { tab in
                Button {
                    selection = tab.id
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .buttonStyle(InspectorTabButtonStyle(
                    isSelected: selection == tab.id,
                    overrideKey: Self.overrideKey(tab.id),
                    mark: reduceMotion ? nil : markSpace
                ))
                // The strip takes the keyboard as a whole, not tab by tab.
                .focusable(false)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab.id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .background(TabStripKeyHandler(move: move))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }
}

/// The tab strip's place in the key loop: an AppKit view behind the strip
/// that takes ← and → while it has the keyboard and draws the focus ring
/// around the strip. Like the system's tab and segmented controls it joins
/// the key loop only with full keyboard access on. Clicks pass through it
/// to the tabs, and it is not an accessibility element of its own.
struct TabStripKeyHandler: NSViewRepresentable {
    var move: (Int) -> Void

    func makeNSView(context: Context) -> TabStripKeyView {
        let view = TabStripKeyView()
        view.onMove = move
        return view
    }

    func updateNSView(_ view: TabStripKeyView, context: Context) {
        view.onMove = move
    }
}

final class TabStripKeyView: NSView {
    var onMove: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        switch (event.keyCode, plain) {
        case (123, true): onMove?(-1)
        case (124, true): onMove?(1)
        default: super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        noteFocusRingMaskChanged()
    }
}

/// One tab of the strip: secondary at rest, a faint fill on hover and a
/// firmer one while pressed; selected, it stands on a lifted mark (opaque
/// surface, hairline, soft shadow) with its icon in the accent color.
struct InspectorTabButtonStyle: ButtonStyle {
    var isSelected: Bool
    var overrideKey: String
    /// Where the selection mark slides between tabs; nil to fade it instead.
    var mark: Namespace.ID?

    func makeBody(configuration: Configuration) -> some View {
        TabButtonBody(configuration: configuration, isSelected: isSelected, overrideKey: overrideKey, mark: mark)
    }

    private struct TabButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        let overrideKey: String
        let mark: Namespace.ID?
        @State private var hovering = false
        @Environment(\.pointerOverrides) private var overrides
        @Environment(\.colorScheme) private var colorScheme

        private var pointer: PointerState {
            if let forced = overrides[overrideKey] { return forced }
            if configuration.isPressed { return .pressed }
            return hovering ? .hovered : .idle
        }

        var body: some View {
            configuration.label
                .labelStyle(TabLabelStyle(isSelected: isSelected))
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected || pointer != .idle ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .contentShape(Rectangle())
                .background { background }
                .onHover { hovering = $0 }
                .animation(InteractionStyle.hover, value: pointer)
        }

        private var background: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            let dark = colorScheme == .dark
            return ZStack {
                if isSelected {
                    selectionMark(shape, dark: dark)
                }
                shape.fill(Color.primary.opacity(fill(dark: dark)))
            }
        }

        @ViewBuilder
        private func selectionMark(_ shape: RoundedRectangle, dark: Bool) -> some View {
            let surface = shape
                .fill(dark ? Color.white.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 1.5, x: 0, y: 1)
                .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.06), lineWidth: 0.5))
            if let mark {
                surface.matchedGeometryEffect(id: "selection", in: mark)
            } else {
                surface.transition(.opacity)
            }
        }

        /// Hover and press on top of the tab, selected or not.
        private func fill(dark: Bool) -> Double {
            switch pointer {
            case .idle: return 0
            // Kept well below the selection mark, so a hovered tab never
            // passes for the selected one.
            case .hovered: return isSelected ? 0 : dark ? 0.045 : 0.045
            case .pressed: return dark ? 0.12 : 0.08
            }
        }
    }
}

/// Icon and title side by side; the selected tab's icon takes the accent.
private struct TabLabelStyle: LabelStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            configuration.title
        }
    }
}

/// The three tabs' contents, each in a hosting view of its own made the
/// first time its tab is shown and then kept. Only the selected one is in
/// the window, as a tab view does it: a hidden tab takes no keys (the Esc
/// monitor of the list, the Tab key loop), no focus request and no
/// accessibility focus, while its views, their state and their scroll
/// positions wait for its return.
struct InspectorPages: NSViewRepresentable {
    let selection: AppState.InspectorTab
    let state: AppState
    let environment: InspectorPageEnvironment

    func makeNSView(context: Context) -> InspectorPagesView {
        InspectorPagesView()
    }

    func updateNSView(_ view: InspectorPagesView, context: Context) {
        view.show(
            selection,
            environment: environment,
            revealRequestID: state.sidebarRevealRequestID,
            replayReveal: { [weak state] in state?.sidebarRevealRequestID = UUID() },
            make: page(for:)
        )
    }

    private func page(for tab: AppState.InspectorTab) -> AnyView {
        let content: AnyView
        switch tab {
        case .annotations: content = AnyView(AnnotationsView())
        case .notes: content = AnyView(DocumentNotesView())
        case .agent: content = AnyView(AgentContextView())
        }
        return AnyView(environment.apply(to: content, state: state))
    }
}

/// What the tab contents read from the SwiftUI environment that a hosting
/// view of their own would not inherit. Checked against every view under
/// the three tabs: they read `AppState` and the two pointer-override maps
/// (cards; Agent's session path and section headers). The rest they read
/// (color scheme, display scale, Reduce Motion) a hosting view takes from
/// its window and the system, and none of them reads `AppUpdates`.
struct InspectorPageEnvironment: Equatable {
    var cardPointerOverrides: [UUID: PointerState]
    var pointerOverrides: [String: PointerState]

    func apply<V: View>(to content: V, state: AppState) -> some View {
        content
            .environmentObject(state)
            .environment(\.cardPointerOverrides, cardPointerOverrides)
            .environment(\.pointerOverrides, pointerOverrides)
    }
}

final class InspectorPagesView: NSView {
    private(set) var pages: [AppState.InspectorTab: NSHostingView<AnyView>] = [:]
    private(set) var shownTab: AppState.InspectorTab?
    private var environment: InspectorPageEnvironment?
    /// The sidebar reveal request current when this inspector first showed.
    private var revealRequestAtStart: UUID?

    func show(
        _ tab: AppState.InspectorTab,
        environment newEnvironment: InspectorPageEnvironment,
        revealRequestID: UUID,
        replayReveal: @escaping @MainActor () -> Void,
        make: (AppState.InspectorTab) -> AnyView
    ) {
        if revealRequestAtStart == nil { revealRequestAtStart = revealRequestID }
        // The contents observe the app state themselves; their root views
        // are replaced, the hidden ones too, only when what was passed in
        // changed.
        if newEnvironment != environment {
            environment = newEnvironment
            for (key, page) in pages { page.rootView = make(key) }
        }
        let page: NSHostingView<AnyView>
        var made = false
        if let existing = pages[tab] {
            page = existing
        } else {
            page = NSHostingView(rootView: make(tab))
            // The page fills this view; it must not size it.
            page.sizingOptions = []
            page.autoresizingMask = [.width, .height]
            pages[tab] = page
            made = true
        }
        shownTab = tab
        guard page.superview !== self else { return }
        for other in subviews where other !== page { other.removeFromSuperview() }
        page.frame = bounds
        addSubview(page)

        // The list scrolls to a card when the reveal request changes. A list
        // made after the request (a highlight clicked in the PDF while Notes
        // or Agent showed, and the Annotations tab not yet shown since this
        // inspector appeared) takes the request as its first value and never
        // sees a change. So it is asked again once the list is drawn; only
        // here, once per page, so it cannot repeat.
        if made, tab == .annotations, revealRequestID != revealRequestAtStart {
            Task { @MainActor [weak page] in
                page?.layoutSubtreeIfNeeded()
                replayReveal()
            }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for page in subviews { page.frame = bounds }
    }
}

// MARK: - Document notes

struct DocumentNotesView: View {
    @EnvironmentObject private var state: AppState
    @State private var editorFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Document notes")
                    .font(.headline)
                Spacer()
                Text("not anchored · autosaves to notes.md")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            NotesTextEditor(text: $state.notes, isFocused: $editorFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(TextBoxChrome(
                    isFocused: editorFocused,
                    placeholder: state.notes.isEmpty ? "Notes on the paper as a whole" : nil,
                    textInset: NotesTextEditor.textInset
                ))
                .onChange(of: state.notes) { _ in
                    state.scheduleNotesSave()
                }
        }
        .padding(12)
    }
}

/// The notes box: an NSTextView, like the comment box, so the focus ring can
/// follow the keyboard exactly. Esc does nothing here (NSTextView would open
/// the completion list).
struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    static let textInset = NSSize(width: 4, height: 6)

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotesTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = Self.textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Document notes")
        textView.string = text
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let textView = context.coordinator.textView,
           !textView.hasMarkedText(),
           textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextEditor
        weak var textView: NotesTextView?

        init(parent: NotesTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.cancelOperation(_:))
        }

        func focusChanged(_ focused: Bool) {
            // Responder changes can happen inside a view update; publish after.
            Task { @MainActor [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }
    }
}

final class NotesTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

/// The detachable window: composer on top, document notes below, so the main
/// window can give the whole sidebar to the annotations list.
struct NotesWindowView: View {
    var body: some View {
        VSplitView {
            CommentComposer()
                .frame(minHeight: 180, idealHeight: 260)
            DocumentNotesView()
                .frame(minHeight: 160)
        }
    }
}

// MARK: - Agent

struct AgentContextView: View {
    @EnvironmentObject private var state: AppState
    @State private var showUnderstanding = true
    @State private var showContext = false
    /// Where a click on the session path copies it. A test passes its own,
    /// so the user's clipboard is left alone.
    var pasteboard: NSPasteboard = .general

    private var modeDescription: String {
        switch state.readingMode {
        case .preread:
            return "The agent reads the whole paper first and fills its map before you comment."
        case .together:
            return "The agent reads only what you have reached: each highlight with its surrounding text, and pages up to the furthest one you have opened. It never reads ahead."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reading mode")
                .font(.headline)
            Picker("Reading mode", selection: $state.readingMode) {
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(state.sessionPaths == nil)
            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Copy agent prompt", action: state.copyAgentPrompt)
                    .buttonStyle(.borderedProminent)
                    .hoverHighlight()
                    .help("Copy a prompt for your agent client; it names the session folder and the reading mode")
                Button("Reveal folder", action: state.revealSessionFolder)
                    .hoverHighlight()
            }

            if let root = state.sessionPaths?.root.path {
                SessionPathButton(path: root) { copySessionPath(root) }
            }

            Divider()

            Text(state.agentReplies.isEmpty
                ? "Replies the agent writes to agent/replies/ appear under their comments in Annotations."
                : "\(state.agentReplies.count) agent repl\(state.agentReplies.count == 1 ? "y" : "ies") shown under comments in Annotations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Agent’s reading of the paper", isExpanded: $showUnderstanding) {
                preview(state.sharedUnderstandingPreview, maxHeight: 260)
            }
            .disclosureGroupStyle(HoverDisclosureStyle())

            DisclosureGroup("Current context sent to the agent", isExpanded: $showContext) {
                preview(state.currentContextPreview, maxHeight: 210)
            }
            .disclosureGroupStyle(HoverDisclosureStyle())
            Spacer()
        }
        .padding(12)
    }

    private func preview(_ text: String, maxHeight: CGFloat) -> some View {
        AgentPreviewPanel(text: text, maxHeight: maxHeight)
    }

    private func copySessionPath(_ path: String) {
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        state.statusMessage = "Session path copied"
    }
}

/// A read-only preview set into the tab as an inset well. It is as tall as
/// its text up to `maxHeight` and scrolls beyond that: a fixed-height well
/// would show an empty box under a short text. When the tab is short (a low
/// window, both sections open) it gives up height down to a few lines, so
/// the tab's controls stay inside it.
struct AgentPreviewPanel: View {
    let text: String
    let maxHeight: CGFloat
    @State private var textHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(minHeight: min(fittedHeight, Self.minimumHeight), idealHeight: fittedHeight, maxHeight: fittedHeight)
        .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
        .background(InsetPanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fittedHeight: CGFloat { min(max(textHeight, 30), maxHeight) }
    /// About three lines of the preview's text.
    static let minimumHeight: CGFloat = 56

    private struct TextHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

/// The session folder's path: a click copies it. A copy glyph appears on
/// hover and turns into a check for a moment after the copy.
struct SessionPathButton: View {
    let path: String
    var copy: () -> Void
    @State private var copiedAt: Date?

    var body: some View {
        Button {
            copy()
            let now = Date()
            copiedAt = now
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copiedAt == now { copiedAt = nil }
            }
        } label: {
            SessionPathLabel(path: path, copied: copiedAt != nil)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(SurfaceButtonStyle(overrideKey: Self.overrideKey))
        // The hover fill reaches past the text column; the path stays aligned
        // with the text above and below.
        .padding(.horizontal, -6)
        .help("Click to copy the session folder’s path")
        .accessibilityLabel("Session folder")
        .accessibilityValue(path)
        .accessibilityHint("Copies the path")
    }

    static let overrideKey = "agent.session-path"
}

private struct SessionPathLabel: View {
    let path: String
    let copied: Bool
    @Environment(\.surfacePointer) private var pointer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(copied || pointer != .idle ? 1 : 0)
                .animation(InteractionStyle.hover, value: copied)
        }
    }
}
