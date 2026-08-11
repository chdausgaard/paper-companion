import PaperCompanionCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if state.document == nil {
                WelcomeView()
            } else {
                HSplitView {
                    PDFReaderView(state: state)
                        .frame(minWidth: 560, minHeight: 620)

                    InspectorView()
                        .frame(minWidth: 340, idealWidth: 390, maxWidth: 500)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.openPDF()
                } label: {
                    Label("Open PDF", systemImage: "doc")
                }
                .keyboardShortcut("o", modifiers: .command)
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
                .help("Open the notes and comment editor in a separate window")
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
        .safeAreaInset(edge: .bottom) {
            StatusBar()
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

private struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.secondary)
            Text("Paper Companion")
                .font(.largeTitle.weight(.semibold))
            Text("Read, highlight, and build a shared understanding with an external agent—without modifying the original PDF.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Open PDF…", action: state.openPDF)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
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
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct InspectorView: View {
    @State private var tab = InspectorTab.notes

    var body: some View {
        TabView(selection: $tab) {
            NotesView()
                .tabItem { Label("Notes", systemImage: "square.and.pencil") }
                .tag(InspectorTab.notes)
            HighlightsView()
                .tabItem { Label("Highlights", systemImage: "highlighter") }
                .tag(InspectorTab.highlights)
            AgentContextView()
                .tabItem { Label("Agent", systemImage: "sparkles") }
                .tag(InspectorTab.agent)
        }
        .padding(.top, 4)
    }

    private enum InspectorTab: Hashable {
        case notes, highlights, agent
    }
}

struct NotesView: View {
    @EnvironmentObject private var state: AppState
    @State private var showSavedComments = true

    private var linkedButtonTitle: String {
        if state.selectedHighlight != nil { return "Save linked to highlight" }
        if state.currentSelection != nil { return "Highlight selection + save" }
        return "Save linked comment"
    }

    private var commentExplanation: String {
        if state.selectedHighlight != nil {
            return "Linked saves with the active highlighted quote. Page-only saves to page \(state.currentPageLabel) and ignores that quote."
        }
        if state.currentSelection != nil {
            return "Linked creates a highlight from the selected text and attaches this comment. Page-only saves to page \(state.currentPageLabel) and ignores the selection."
        }
        return "Page-only comments are anchored to page \(state.currentPageLabel). Select text to create a quote-linked comment."
    }

    private var sortedComments: [CommentRecord] {
        state.activeComments.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Active context") {
                VStack(alignment: .leading, spacing: 6) {
                    if let highlight = state.selectedHighlight {
                        Text("Highlight · page \(highlight.pageLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(highlight.quote)
                            .font(.callout)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    } else if let selection = state.currentSelection {
                        Text("Current selection · page \(selection.primaryPageLabel ?? state.currentPageLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(selection.selectedText)
                            .font(.callout)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    } else {
                        Text("Page \(state.currentPageLabel). Select and highlight text to create a precise anchor, or save a page-level comment.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("New comment")
                .font(.headline)
            TextEditor(text: $state.commentDraft)
                .font(.body)
                .frame(minHeight: 82, maxHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text(commentExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save page-only") {
                    state.addComment(linkToHighlight: false)
                }
                .help("Save a comment anchored only to the current page; any text selection is ignored")

                Button(linkedButtonTitle) {
                    state.addComment(linkToHighlight: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.selectedHighlight == nil && state.currentSelection == nil)
                .help("Save a comment linked to highlighted text; a current selection becomes a new highlight")
            }

            Divider()
            DisclosureGroup(
                "Saved comments (\(state.activeComments.count))",
                isExpanded: $showSavedComments
            ) {
                if sortedComments.isEmpty {
                    Text("No saved comments yet. A saved comment will remain visible here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sortedComments) { comment in
                                SavedCommentRow(comment: comment)
                                if comment.id != sortedComments.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 155)
                }
                Text("Stored in `comments.md` and `state/comments.json` inside this paper’s session folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }

            Divider()
            HStack {
                Text("Document notes (not anchored)")
                    .font(.headline)
                Spacer()
                Button("Save", action: state.saveNotes)
                    .help("Save the document-level notes now; they also autosave as you type")
            }
            Text("A free-form Markdown scratchpad for the paper as a whole. It is not linked to a page, selection, or highlight and is stored in `notes.md`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $state.notes)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: state.notes) { _ in
                    state.scheduleNotesSave()
                }
        }
        .padding(12)
    }
}

private struct SavedCommentRow: View {
    @EnvironmentObject private var state: AppState
    let comment: CommentRecord

    private var linkedHighlight: HighlightRecord? {
        guard let highlightID = comment.highlightID else { return nil }
        return state.highlights.first { $0.id == highlightID }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.selectComment(comment)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        comment.highlightID == nil
                            ? "Page-only · page \(comment.pageLabel ?? "?")"
                            : "Linked to highlight · page \(comment.pageLabel ?? "?")",
                        systemImage: comment.highlightID == nil ? "doc.text" : "highlighter"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Text(comment.verbatim)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    if let quote = linkedHighlight?.quote {
                        Text("“\(quote.normalizedForSearch)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Go to this comment’s page or linked highlight")

            Button(role: .destructive) {
                state.deleteComment(comment.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this comment; press ⌘Z to restore it")
        }
        .contextMenu {
            Button("Delete Comment", role: .destructive) {
                state.deleteComment(comment.id)
            }
        }
    }
}

private struct HighlightsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(state.activeHighlights.count) highlights")
                    .font(.headline)
                Spacer()
                Button("Export…", action: state.exportComments)
                    .help("Export highlights and comments as Markdown")
            }

            Toggle("Auto-highlight selections", isOn: $state.autoHighlightEnabled)
                .toggleStyle(.switch)
                .help("When enabled, finishing a text selection creates a highlight automatically")

            Text("Manual: select text and press ⇧⌘H. Remove a highlight with the trash button; press ⌘Z to undo.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.activeHighlights.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Highlights")
                        .font(.headline)
                    Text("Select text and press ⇧⌘H, or turn on Auto-highlight selections.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.activeHighlights) { highlight in
                    HStack(spacing: 8) {
                        Button {
                            state.selectHighlight(highlight)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Page \(highlight.pageLabel)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(highlight.quote.normalizedForSearch)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                let linkedCount = state.activeComments.filter { $0.highlightID == highlight.id }.count
                                if linkedCount > 0 {
                                    Label("\(linkedCount) comment\(linkedCount == 1 ? "" : "s")", systemImage: "text.bubble")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            state.deleteHighlight(highlight.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this highlight; linked comments are retained. Press ⌘Z to undo.")
                    }
                    .contextMenu {
                        Button("Remove Highlight", role: .destructive) {
                            state.deleteHighlight(highlight.id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
    }
}

private struct AgentContextView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("External agent bridge")
                .font(.headline)
            Text("Paper Companion writes a bounded snapshot of the active page or highlight. Your agent keeps its own transcript and shared understanding in the same session folder.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Copy agent prompt", action: state.copyAgentPrompt)
                    .buttonStyle(.borderedProminent)
                Button("Reveal folder", action: state.revealSessionFolder)
                Button(action: state.refreshAgentFiles) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload agent-owned files")
            }

            if let root = state.sessionPaths?.root.path {
                Text(root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Divider()
            DisclosureGroup("Current context", isExpanded: .constant(true)) {
                ScrollView {
                    Text(state.currentContextPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 210)
            }

            DisclosureGroup("Shared understanding") {
                ScrollView {
                    Text(state.sharedUnderstandingPreview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            Spacer()
        }
        .padding(12)
    }
}
