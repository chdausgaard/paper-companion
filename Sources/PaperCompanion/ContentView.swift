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

private struct StatusBar: View {
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

struct InspectorView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView(selection: $state.inspectorTab) {
            AnnotationsView()
                .tabItem { Label("Annotations", systemImage: "highlighter") }
                .tag(AppState.InspectorTab.annotations)
            DocumentNotesView()
                .tabItem { Label("Notes", systemImage: "square.and.pencil") }
                .tag(AppState.InspectorTab.notes)
            AgentContextView()
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(AppState.InspectorTab.agent)
        }
        .padding(.top, 4)
    }
}

// MARK: - Annotations

/// Highlights and comments as one list in paper order, with the composer
/// underneath. One selected entry is expanded to full text and tinted in the
/// PDF; clicking a highlight in the PDF selects its entry here.
struct AnnotationsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VSplitView {
            AnnotationList()
                .frame(minHeight: 200, idealHeight: 460)
            CommentComposer()
                .frame(minHeight: 150, idealHeight: 210)
        }
    }
}

private struct AnnotationList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let entries = state.annotationEntries
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(header(entries))
                    .font(.headline)
                Spacer()
                if state.selectedEntryID != nil {
                    Button("Deselect", action: state.clearEntrySelection)
                        .controlSize(.small)
                        .help("Collapse the selected annotation")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No annotations")
                        .font(.headline)
                    Text("Select text and press ⇧⌘H, or type a comment below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                AnnotationRow(
                                    entry: entry,
                                    expanded: state.selectedEntryID == entry.id
                                )
                                .id(entry.id)
                                Divider().padding(.horizontal, 12)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: state.sidebarRevealRequestID) { _ in
                        guard let id = state.sidebarRevealID else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func header(_ entries: [AnnotationEntry]) -> String {
        let highlights = entries.filter { $0.highlight != nil }.count
        let comments = entries.reduce(0) { $0 + $1.comments.count }
        let replies = state.agentReplies.keys.filter { id in
            entries.contains { $0.comments.contains { $0.id == id } }
        }.count
        var parts = ["\(highlights) highlight\(highlights == 1 ? "" : "s")", "\(comments) comment\(comments == 1 ? "" : "s")"]
        if replies > 0 { parts.append("\(replies) repl\(replies == 1 ? "y" : "ies")") }
        return parts.joined(separator: " · ")
    }
}

private struct AnnotationRow: View {
    @EnvironmentObject private var state: AppState
    let entry: AnnotationEntry
    let expanded: Bool
    @State private var editingCommentID: UUID?
    @State private var editDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("p. \(entry.pageLabel)", systemImage: entry.highlight == nil ? "doc.text" : "highlighter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entry.highlight != nil, entry.comments.isEmpty {
                    Text("· no comment")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !expanded, entry.comments.contains(where: { state.agentReplies[$0.id] != nil }) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The agent has replied")
                }
                if entry.highlight != nil, entry.comments.isEmpty {
                    trashButton(help: "Remove this highlight (⌘Z to undo)") {
                        if let highlight = entry.highlight { state.deleteHighlight(highlight.id) }
                    }
                }
            }

            if let highlight = entry.highlight {
                Text("“\(highlight.quote.normalizedForSearch)”")
                    .font(.callout)
                    .foregroundStyle(expanded ? .primary : .secondary)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }

            ForEach(entry.comments) { comment in
                commentBlock(comment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(expanded ? Color.accentColor.opacity(0.10) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingCommentID == nil else { return }
            state.selectEntry(entry)
        }
        .contextMenu {
            if let highlight = entry.highlight {
                Button("Go to Highlight") { state.selectHighlight(highlight) }
                Divider()
                Button("Remove Highlight", role: .destructive) { state.deleteHighlight(highlight.id) }
            }
            ForEach(entry.comments) { comment in
                Button("Delete Comment: \(comment.verbatim.prefix(30))…", role: .destructive) {
                    state.deleteComment(comment.id)
                }
            }
        }
        .help(expanded ? "" : "Click to show the full text and go to the passage")
    }

    @ViewBuilder
    private func commentBlock(_ comment: CommentRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editingCommentID == comment.id {
                TextEditor(text: $editDraft)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Button("Cancel") { editingCommentID = nil }
                    Button("Save") {
                        state.updateComment(comment.id, verbatim: editDraft)
                        editingCommentID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    if comment.kind == .quiet {
                        Image(systemName: "pencil.line")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Margin note: recorded, not answered by the agent")
                            .padding(.top, 3)
                    }
                    Text(comment.verbatim)
                        .font(.body)
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if expanded {
                        Button {
                            editDraft = comment.verbatim
                            editingCommentID = comment.id
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit this comment")
                        trashButton(help: "Delete this comment (⌘Z to undo)") {
                            state.deleteComment(comment.id)
                        }
                    }
                }
            }

            if expanded, let reply = state.agentReplies[comment.id] {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Agent", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MarkdownText(reply)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
        }
        .padding(.top, 2)
    }

    private func trashButton(help: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Inline Markdown (emphasis, code, links) rendered through AttributedString;
/// falls back to the raw text when parsing fails.
private struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}

// MARK: - Composer

struct CommentComposer: View {
    @EnvironmentObject private var state: AppState

    private var anchorDescription: (icon: String, text: String) {
        if let highlight = state.selectedHighlight {
            return ("highlighter", "Linked to highlight · p. \(highlight.pageLabel) · “\(highlight.quote.normalizedForSearch)”")
        }
        if let selection = state.currentSelection {
            return ("text.cursor", "Selection · p. \(selection.primaryPageLabel ?? state.currentPageLabel) · will be highlighted")
        }
        return ("doc.text", "Page \(state.currentPageLabel) · select text to link a comment to a passage")
    }

    private var saveTitle: String {
        if state.selectedHighlight != nil { return "Save linked" }
        if state.currentSelection != nil { return "Highlight + save" }
        return "Save to page"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(anchorDescription.text, systemImage: anchorDescription.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if state.selectedHighlight != nil {
                    Button("Detach", action: state.clearEntrySelection)
                        .controlSize(.small)
                        .help("Stop linking to the selected highlight; the next comment goes to the page")
                }
            }

            TextEditor(text: $state.commentDraft)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack(spacing: 8) {
                Button {
                    state.addQuickNote()
                } label: {
                    Label("Margin note", systemImage: "pencil.line")
                }
                .help("Save as a margin note (⇧⌘M): recorded and anchored, but the agent will not respond")

                Spacer()

                Button("Page-only") {
                    state.addComment(linkToHighlight: false)
                }
                .disabled(!state.hasCommentAnchor)
                .help("Save to page \(state.currentPageLabel) and ignore the selection or highlight (⇧⌘↩)")

                Button(saveTitle) {
                    state.saveCommentFromKeyboard()
                }
                .buttonStyle(.borderedProminent)
                .help(state.hasCommentAnchor
                    ? "Save linked to the highlighted text; a selection becomes a new highlight (⌘↩)"
                    : "Save anchored to page \(state.currentPageLabel) (⌘↩)")
            }
        }
        .padding(12)
    }
}

// MARK: - Document notes

struct DocumentNotesView: View {
    @EnvironmentObject private var state: AppState

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
            TextEditor(text: $state.notes)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: state.notes) { _ in
                    state.scheduleNotesSave()
                }
        }
        .padding(12)
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

private struct AgentContextView: View {
    @EnvironmentObject private var state: AppState
    @State private var showUnderstanding = true
    @State private var showContext = false

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
                    .help("Copy a prompt for your agent client; it names the session folder and the reading mode")
                Button("Reveal folder", action: state.revealSessionFolder)
            }

            if let root = state.sessionPaths?.root.path {
                Text(root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Divider()

            Text(state.agentReplies.isEmpty
                ? "Replies the agent writes to agent/replies/ appear under their comments in Annotations."
                : "\(state.agentReplies.count) agent repl\(state.agentReplies.count == 1 ? "y" : "ies") shown under comments in Annotations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Agent’s reading of the paper", isExpanded: $showUnderstanding) {
                ScrollView {
                    Text(state.sharedUnderstandingPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }

            DisclosureGroup("Current context sent to the agent", isExpanded: $showContext) {
                ScrollView {
                    Text(state.currentContextPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 210)
            }
            Spacer()
        }
        .padding(12)
    }
}
