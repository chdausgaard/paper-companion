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
