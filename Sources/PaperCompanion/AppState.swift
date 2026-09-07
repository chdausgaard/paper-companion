import AppKit
import Foundation
import PDFKit
import PaperCompanionCore
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var document: PDFDocument?
    @Published var sourceURL: URL?
    @Published var manifest: SessionManifest?
    @Published var sessionPaths: SessionPaths?
    @Published var highlights: [HighlightRecord] = []
    @Published var comments: [CommentRecord] = []
    @Published var notes = ""
    @Published var currentSelection: SelectionSnapshot?
    @Published var selectedHighlightID: UUID?
    /// A selected page-only or orphaned comment. Mutually exclusive with
    /// `selectedHighlightID`: an entry is one or the other.
    @Published var selectedCommentID: UUID?
    @Published var inspectorTab = InspectorTab.annotations
    /// Bumped when the sidebar should scroll an entry into view, for example
    /// after a highlight is clicked in the PDF.
    @Published var sidebarRevealID: UUID?
    @Published var sidebarRevealRequestID = UUID()
    /// Bumped when the PDF view should take keyboard focus, so ⌫ after a
    /// click in the list reaches the entry rather than a text field.
    @Published var pdfFocusRequestID = UUID()
    @Published var agentReplies: [UUID: String] = [:]
    @Published var currentPageIndex = 0
    @Published var currentPageLabel = "1"
    @Published var commentDraft = ""
    @Published var searchQuery = ""
    @Published var searchRequestID = UUID()
    @Published var navigationPageIndex: Int?
    @Published var navigationHighlightID: UUID?
    @Published var navigationRequestID = UUID()
    @Published var statusMessage = "Open a PDF to begin"
    @Published var errorMessage: String?
    @Published var currentContextPreview = "No active session."
    @Published var sharedUnderstandingPreview = "No agent notes yet."
    @Published var autoHighlightEnabled = UserDefaults.standard.bool(forKey: "PaperCompanion.autoHighlightEnabled") {
        didSet {
            UserDefaults.standard.set(autoHighlightEnabled, forKey: "PaperCompanion.autoHighlightEnabled")
            if !autoHighlightEnabled { autoHighlightTask?.cancel() }
        }
    }

    var undoManager = UndoManager()

    enum InspectorTab: Hashable {
        case annotations, notes, agent
    }

    let recentPapers = RecentPapersStore()
    private let repository = SessionRepository()
    private var currentPageText = ""
    private var contextWriteTask: Task<Void, Never>?
    private var agentWatchTask: Task<Void, Never>?
    private var agentFilesFingerprint = ""
    private var annotatedPDFTask: Task<Void, Never>?
    private var annotatedPDFSignature = ""
    private var pageSaveTask: Task<Void, Never>?
    private var notesSaveTask: Task<Void, Never>?
    private var autoHighlightTask: Task<Void, Never>?
    private var lastAutoHighlightSignature: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        if let path = arguments.first(where: { $0.lowercased().hasSuffix(".pdf") }) {
            Task { @MainActor [weak self] in
                self?.loadPDF(at: URL(fileURLWithPath: path))
            }
        }
    }

    var activeHighlights: [HighlightRecord] {
        highlights.filter { $0.deletedAt == nil }
    }

    var activeComments: [CommentRecord] {
        comments.filter { $0.status != "deleted" }
    }

    var selectedHighlight: HighlightRecord? {
        guard let selectedHighlightID else { return nil }
        return highlights.first { $0.id == selectedHighlightID && $0.deletedAt == nil }
    }

    /// Highlights and comments merged, in reading order.
    var annotationEntries: [AnnotationEntry] {
        AnnotationEntry.build(highlights: highlights, comments: comments)
    }

    var selectedEntryID: UUID? { selectedHighlightID ?? selectedCommentID }

    var readingMode: ReadingMode {
        get { manifest?.readingMode ?? .preread }
        set { setReadingMode(newValue) }
    }

    /// True when a comment can be linked: an active highlight or a live selection.
    var hasCommentAnchor: Bool {
        selectedHighlight != nil || currentSelection != nil
    }

    func openPDF() {
        let panel = NSOpenPanel()
        panel.title = "Open an academic paper"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPDF(at: url)
    }

    func loadPDF(at url: URL) {
        guard let pdfDocument = PDFDocument(url: url) else {
            errorMessage = "Paper Companion could not open this PDF. It may be damaged or protected."
            return
        }

        do {
            let title = documentTitle(document: pdfDocument, url: url)
            let extractedText = extractText(from: pdfDocument)
            // Flush the old session before loading, including when reopening the same PDF.
            notesSaveTask?.cancel()
            if document != nil { try persistStateWithoutEvent() }
            let loaded = try repository.createOrLoadSession(
                pdfURL: url,
                title: title,
                pageCount: pdfDocument.pageCount,
                extractedText: extractedText
            )
            undoManager.removeAllActions()
            sourceURL = url
            document = pdfDocument
            manifest = loaded.manifest
            sessionPaths = loaded.paths
            highlights = loaded.highlights
            comments = loaded.comments
            notes = loaded.notes
            autoHighlightTask?.cancel()
            lastAutoHighlightSignature = nil
            currentSelection = nil
            selectedHighlightID = nil
            selectedCommentID = nil
            currentPageIndex = min(loaded.manifest.lastPageIndex, max(0, pdfDocument.pageCount - 1))
            currentPageLabel = pdfDocument.page(at: currentPageIndex)?.label ?? String(currentPageIndex + 1)
            currentPageText = pdfDocument.page(at: currentPageIndex)?.string ?? ""
            navigationPageIndex = currentPageIndex
            navigationHighlightID = nil
            navigationRequestID = UUID()
            statusMessage = "Session ready · \(pdfDocument.pageCount) pages"
            agentFilesFingerprint = ""
            refreshAgentFiles()
            startAgentFileWatcher()
            try writePageContext()
            recentPapers.record(loaded.manifest)
        } catch {
            errorMessage = "Could not create the reading session: \(error.localizedDescription)"
        }
    }

    func selectionChanged(_ snapshot: SelectionSnapshot?, allowAutoHighlight: Bool = true) {
        autoHighlightTask?.cancel()
        currentSelection = snapshot
        selectedHighlightID = nil
        selectedCommentID = nil
        if snapshot == nil { lastAutoHighlightSignature = nil }
        if let pageIndex = snapshot?.primaryPageIndex {
            currentPageIndex = pageIndex
            currentPageLabel = snapshot?.primaryPageLabel ?? String(pageIndex + 1)
            noteFurthestPage(pageIndex)
        }
        // A drag fires this many times a second; the context file only needs
        // the state it settles on.
        scheduleContextWrite { [weak self] in
            guard let self else { return }
            try self.writeSelectionContext(self.currentSelection, activeHighlightID: self.selectedHighlightID)
        }
        statusMessage = snapshot == nil ? "Selection cleared" : "Selection ready for highlighting or agent context"

        guard allowAutoHighlight,
              autoHighlightEnabled,
              let snapshot else { return }
        let signature = selectionSignature(snapshot)
        guard signature != lastAutoHighlightSignature else { return }
        autoHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.autoHighlightEnabled,
                  let currentSelection = self.currentSelection,
                  self.selectionSignature(currentSelection) == signature else { return }
            self.lastAutoHighlightSignature = signature
            _ = self.createHighlight(from: currentSelection, origin: "auto_highlight", registerUndo: true)
        }
    }

    func pageChanged(index: Int, label: String, text: String) {
        currentPageIndex = index
        currentPageLabel = label
        currentPageText = text
        noteFurthestPage(index)
        if currentSelection == nil {
            scheduleContextWrite { [weak self] in
                try self?.writePageContext()
            }
        }
        schedulePagePositionSave()
    }

    private func noteFurthestPage(_ index: Int) {
        guard var manifest, index > manifest.furthestPageIndex else { return }
        manifest.furthestPageIndex = index
        self.manifest = manifest
    }

    private func scheduleContextWrite(_ write: @escaping @MainActor () throws -> Void) {
        contextWriteTask?.cancel()
        contextWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try write()
            } catch {
                self.errorMessage = "Could not update agent context: \(error.localizedDescription)"
            }
        }
    }

    func addHighlight() {
        guard let snapshot = currentSelection, !snapshot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Select text in the PDF first"
            return
        }
        _ = createHighlight(from: snapshot, origin: "pdf_selection", registerUndo: true)
    }

    @discardableResult
    private func createHighlight(
        from snapshot: SelectionSnapshot,
        origin: String,
        registerUndo: Bool
    ) -> HighlightRecord? {
        if let existing = activeHighlights.last(where: {
            $0.quote == snapshot.selectedText && $0.locations == snapshot.locations
        }) {
            selectedHighlightID = existing.id
            statusMessage = "This selection is already highlighted · page \(existing.pageLabel)"
            return existing
        }
        let highlight = HighlightRecord(
            quote: snapshot.selectedText,
            prefix: snapshot.prefix,
            suffix: snapshot.suffix,
            locations: snapshot.locations
        )
        highlights.append(highlight)
        selectedHighlightID = highlight.id
        selectedCommentID = nil
        do {
            try persistState(eventKind: "highlight_created", recordID: highlight.id, origin: origin)
            try writeSelectionContext(snapshot, activeHighlightID: highlight.id)
            if registerUndo { registerUndoForCreatedHighlight(highlight.id) }
            statusMessage = "Highlight saved · page \(highlight.pageLabel)"
            return highlight
        } catch {
            highlights.removeAll { $0.id == highlight.id }
            if selectedHighlightID == highlight.id { selectedHighlightID = nil }
            errorMessage = "Could not save the highlight: \(error.localizedDescription)"
            return nil
        }
    }

    func addComment(linkToHighlight: Bool, kind: CommentRecord.Kind = .discuss) {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "Type or dictate a comment first"
            return
        }

        var linkedHighlight = linkToHighlight ? selectedHighlight : nil
        if linkToHighlight, linkedHighlight == nil, let currentSelection {
            linkedHighlight = createHighlight(
                from: currentSelection,
                origin: "comment_anchor",
                registerUndo: false
            )
        }
        if linkToHighlight, linkedHighlight == nil {
            statusMessage = "Select text or choose an existing highlight first"
            return
        }
        let comment = CommentRecord(
            highlightID: linkedHighlight?.id,
            pageIndex: linkedHighlight?.pageIndex ?? currentPageIndex,
            pageLabel: linkedHighlight?.pageLabel ?? currentPageLabel,
            verbatim: text,
            kind: kind
        )
        comments.append(comment)
        do {
            // The event kind is what an agent watcher keys on: a margin note is
            // journalled under a name that does not match its comment trigger.
            try persistState(
                eventKind: kind == .quiet ? "quicknote_created" : "comment_created",
                recordID: comment.id,
                origin: "typed"
            )
            commentDraft = ""
            if linkedHighlight == nil {
                selectedHighlightID = nil
                selectedCommentID = comment.id
            }
            if kind == .quiet {
                statusMessage = "Margin note saved · page \(comment.pageLabel ?? currentPageLabel) · not sent to the agent"
            } else {
                statusMessage = linkedHighlight == nil
                    ? "Page-only comment saved · visible under Saved comments"
                    : "Comment linked to highlighted text · visible under Saved comments"
            }
        } catch {
            comments.removeAll { $0.id == comment.id }
            errorMessage = "Could not save the comment: \(error.localizedDescription)"
        }
    }

    /// ⌘↩: linked when there is an anchor, page-only otherwise.
    func saveCommentFromKeyboard() {
        addComment(linkToHighlight: hasCommentAnchor)
    }

    /// A margin note: anchored like any other comment, but journalled so the
    /// agent records it without responding. Links to the current selection or
    /// highlight when there is one, so the anchor is not lost.
    func addQuickNote() {
        addComment(linkToHighlight: hasCommentAnchor, kind: .quiet)
    }

    /// Replaces a saved comment's text in place, keeping its anchor and ID so
    /// the agent's transcript and reply still point at it.
    func updateComment(_ id: UUID, verbatim: String) {
        let text = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = comments.firstIndex(where: { $0.id == id }),
              !text.isEmpty,
              comments[index].verbatim != text else { return }
        let previous = comments[index].verbatim
        let previousUpdatedAt = comments[index].updatedAt
        undoManager.registerUndo(withTarget: self) { target in
            target.updateComment(id, verbatim: previous)
            target.comments[index].updatedAt = previousUpdatedAt
        }
        undoManager.setActionName("Edit Comment")
        comments[index].verbatim = text
        comments[index].updatedAt = Date()
        do {
            try persistState(eventKind: "comment_updated", recordID: id, origin: "typed")
            statusMessage = "Comment updated"
        } catch {
            errorMessage = "Could not update the comment: \(error.localizedDescription)"
        }
    }

    func saveNotes() {
        do {
            try persistState(eventKind: "notes_saved", recordID: nil, origin: "typed")
            statusMessage = "Notes saved"
        } catch {
            errorMessage = "Could not save notes: \(error.localizedDescription)"
        }
    }

    func scheduleNotesSave() {
        notesSaveTask?.cancel()
        notesSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.persistStateWithoutEvent()
            } catch {
                self.errorMessage = "Could not autosave notes: \(error.localizedDescription)"
            }
        }
    }

    func deleteHighlight(_ id: UUID) {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        applyHighlightDeletion(id, deletedAt: Date(), actionName: "Remove Highlight")
    }

    func setHighlightColor(_ id: UUID, color: String) {
        guard HighlightColor(rawValue: color) != nil,
              let index = highlights.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              highlights[index].color != color else { return }
        let previous = highlights[index].color
        highlights[index].color = color
        do {
            try persistState(eventKind: "highlight_color_changed", recordID: id, origin: "app_action")
            undoManager.registerUndo(withTarget: self) { $0.setHighlightColor(id, color: previous) }
            undoManager.setActionName("Change Highlight Color")
        } catch {
            highlights[index].color = previous
            errorMessage = "Could not save the highlight color: \(error.localizedDescription)"
        }
    }

    func deleteSelectedHighlight() {
        guard let selectedHighlightID else { return }
        deleteHighlight(selectedHighlightID)
    }

    private func registerUndoForCreatedHighlight(_ id: UUID) {
        undoManager.registerUndo(withTarget: self) { target in
            target.applyHighlightDeletion(id, deletedAt: Date(), actionName: "Highlight")
        }
        undoManager.setActionName("Highlight")
    }

    private func applyHighlightDeletion(_ id: UUID, deletedAt: Date?, actionName: String, restoringComments: [CommentRecord]? = nil) {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              highlights[index].deletedAt != deletedAt else { return }
        let previousDeletedAt = highlights[index].deletedAt
        let previousComments = comments.filter { $0.highlightID == id }
        undoManager.registerUndo(withTarget: self) { target in
            target.applyHighlightDeletion(id, deletedAt: previousDeletedAt, actionName: actionName, restoringComments: previousComments)
        }
        undoManager.setActionName(actionName)
        highlights[index].deletedAt = deletedAt
        if let restoringComments {
            for comment in restoringComments {
                if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index] = comment }
            }
        } else if let deletedAt {
            for index in comments.indices where comments[index].highlightID == id && comments[index].status != "deleted" {
                comments[index].status = "deleted"
                comments[index].updatedAt = deletedAt
            }
        }
        if deletedAt != nil, selectedHighlightID == id { selectedHighlightID = nil }
        do {
            let restored = deletedAt == nil
            let origin: String
            if undoManager.isUndoing {
                origin = "undo"
            } else if undoManager.isRedoing {
                origin = "redo"
            } else {
                origin = "app_action"
            }
            try persistState(
                eventKind: restored ? "highlight_restored" : "highlight_deleted",
                recordID: id,
                origin: origin
            )
            try writePageContext()
            statusMessage = restored
                ? "Highlight restored"
                : "Highlight and linked comments removed · ⌘Z to undo"
        } catch {
            errorMessage = "Could not update the highlight: \(error.localizedDescription)"
        }
    }

    func deleteComment(_ id: UUID) {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        applyCommentState(id, status: "deleted", updatedAt: Date(), actionName: "Delete Comment")
    }

    private func applyCommentState(
        _ id: UUID,
        status: String,
        updatedAt: Date,
        actionName: String
    ) {
        guard let index = comments.firstIndex(where: { $0.id == id }),
              comments[index].status != status else { return }
        let previousStatus = comments[index].status
        let previousUpdatedAt = comments[index].updatedAt
        undoManager.registerUndo(withTarget: self) { target in
            target.applyCommentState(
                id,
                status: previousStatus,
                updatedAt: previousUpdatedAt,
                actionName: actionName
            )
        }
        undoManager.setActionName(actionName)
        comments[index].status = status
        comments[index].updatedAt = updatedAt

        do {
            let restored = status != "deleted"
            let origin: String
            if undoManager.isUndoing {
                origin = "undo"
            } else if undoManager.isRedoing {
                origin = "redo"
            } else {
                origin = "app_action"
            }
            try persistState(
                eventKind: restored ? "comment_restored" : "comment_deleted",
                recordID: id,
                origin: origin
            )
            statusMessage = restored
                ? "Comment restored"
                : "Comment deleted · ⌘Z to undo"
        } catch {
            errorMessage = "Could not update the comment: \(error.localizedDescription)"
        }
    }

    func performUndo() {
        if let textUndoManager = focusedTextUndoManager, textUndoManager.canUndo {
            textUndoManager.undo()
        } else if undoManager.canUndo {
            undoManager.undo()
        }
    }

    func performRedo() {
        if let textUndoManager = focusedTextUndoManager, textUndoManager.canRedo {
            textUndoManager.redo()
        } else if undoManager.canRedo {
            undoManager.redo()
        }
    }

    private var focusedTextUndoManager: UndoManager? {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else { return nil }
        return textView.undoManager
    }

    func selectHighlight(_ highlight: HighlightRecord, navigate: Bool = true) {
        selectedHighlightID = highlight.id
        selectedCommentID = nil
        if navigate {
            navigationPageIndex = highlight.pageIndex
            navigationHighlightID = highlight.id
            navigationRequestID = UUID()
        }
        do {
            let context = CurrentContext(
                sessionID: manifest?.id ?? UUID(),
                sourcePDFPath: manifest?.sourcePDFPath ?? "",
                sourcePDFFingerprint: manifest?.sourcePDFFingerprint ?? "",
                pageIndex: highlight.pageIndex,
                pageLabel: highlight.pageLabel,
                selectedText: highlight.quote,
                prefix: highlight.prefix,
                suffix: highlight.suffix,
                activeHighlightID: highlight.id,
                textStatus: "highlight",
                readingMode: manifest?.readingMode ?? .preread,
                furthestPageIndex: manifest?.furthestPageIndex ?? highlight.pageIndex
            )
            try writeContext(context)
            statusMessage = "Active highlight · page \(highlight.pageLabel)"
        } catch {
            errorMessage = "Could not activate the highlight context: \(error.localizedDescription)"
        }
    }

    func selectComment(_ comment: CommentRecord) {
        if let highlightID = comment.highlightID,
           let highlight = activeHighlights.first(where: { $0.id == highlightID }) {
            selectHighlight(highlight)
            return
        }
        selectedHighlightID = nil
        selectedCommentID = comment.id
        guard let pageIndex = comment.pageIndex else { return }
        navigationPageIndex = pageIndex
        navigationHighlightID = nil
        navigationRequestID = UUID()
        statusMessage = "Page-only comment · page \(comment.pageLabel ?? String(pageIndex + 1))"
    }

    /// Clicking a row in the annotations list: selecting an entry that is
    /// already selected collapses it again.
    func selectEntry(_ entry: AnnotationEntry) {
        if selectedEntryID == entry.id {
            clearEntrySelection()
            return
        }
        if let highlight = entry.highlight {
            selectHighlight(highlight)
        } else if let comment = entry.comments.first {
            selectComment(comment)
        }
        pdfFocusRequestID = UUID()
    }

    /// ⌫ with an entry selected: removes the highlight, or the page-only
    /// comment when that is what is selected. Returns false when there was
    /// nothing to delete so the key can fall through.
    @discardableResult
    func deleteSelectedEntry() -> Bool {
        if let selectedHighlightID {
            deleteHighlight(selectedHighlightID)
            return true
        }
        if let selectedCommentID {
            deleteComment(selectedCommentID)
            self.selectedCommentID = nil
            return true
        }
        return false
    }

    func clearEntrySelection() {
        selectedHighlightID = nil
        selectedCommentID = nil
        scheduleContextWrite { [weak self] in
            try self?.writePageContext()
        }
    }

    /// A highlight clicked in the PDF: select it and bring its row into view,
    /// without scrolling the PDF the user is already looking at.
    func highlightClicked(_ id: UUID) {
        guard let highlight = activeHighlights.first(where: { $0.id == id }) else { return }
        selectHighlight(highlight, navigate: false)
        inspectorTab = .annotations
        sidebarRevealID = id
        sidebarRevealRequestID = UUID()
    }

    func setReadingMode(_ mode: ReadingMode) {
        guard var manifest, let paths = sessionPaths, manifest.readingMode != mode else { return }
        manifest.readingMode = mode
        self.manifest = manifest
        do {
            try repository.writeAgentInstructions(manifest: manifest, paths: paths)
            try persistState(eventKind: "reading_mode_changed", recordID: nil, origin: "app_action")
            try writePageContext()
            statusMessage = mode == .together
                ? "Discover together: the agent reads only what you have reached"
                : "Agent pre-reads the paper"
        } catch {
            errorMessage = "Could not change the reading mode: \(error.localizedDescription)"
        }
    }

    func requestSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchRequestID = UUID()
    }

    func revealAnnotatedPDF() {
        guard let manifest, let paths = sessionPaths else { return }
        let url = paths.annotatedPDF(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "No annotated copy yet · add a highlight or comment first"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealSessionFolder() {
        guard let root = sessionPaths?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func copyAgentPrompt() {
        guard let root = sessionPaths?.root else { return }
        let modeNote = readingMode == .together
            ? " Reading mode is together: do not pre-read, and do not read past the page I have reached."
            : ""
        let prompt = "Use the active Paper Companion reading session at \(root.path). Read its AGENTS.md and current context, then capture my comments as we go.\(modeNote)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        statusMessage = "Agent prompt copied"
    }

    func refreshAgentFiles() {
        guard let paths = sessionPaths else { return }
        currentContextPreview = (try? String(contentsOf: paths.currentContextMarkdown, encoding: .utf8)) ?? "No current context yet."
        sharedUnderstandingPreview = (try? String(contentsOf: paths.sharedUnderstanding, encoding: .utf8)) ?? "No shared understanding yet."
        agentReplies = repository.readAgentReplies(paths: paths)
        agentFilesFingerprint = repository.agentFilesFingerprint(paths: paths)
        scheduleAnnotatedPDFExport()
    }

    /// Polls the agent folder while a session is open. A directory watcher
    /// misses in-place writes, and a stat every second or two is cheap.
    private func startAgentFileWatcher() {
        agentWatchTask?.cancel()
        agentWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, let paths = self.sessionPaths else { continue }
                let fingerprint = self.repository.agentFilesFingerprint(paths: paths)
                if fingerprint != self.agentFilesFingerprint {
                    let before = self.agentReplies.count
                    self.refreshAgentFiles()
                    if self.agentReplies.count > before {
                        self.statusMessage = "Agent replied"
                    }
                }
            }
        }
    }

    func exportComments() {
        guard let manifest else { return }
        let panel = NSSavePanel()
        panel.title = "Export reading comments"
        panel.nameFieldStringValue = "\(sanitizedFilename(manifest.title))-comments.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let markdown = MarkdownExporter.renderComments(
                title: manifest.title,
                highlights: highlights,
                comments: comments
            )
            try repository.writeText(markdown, to: destination)
            statusMessage = "Comments exported"
        } catch {
            errorMessage = "Could not export comments: \(error.localizedDescription)"
        }
    }

    private func persistState(eventKind: String, recordID: UUID?, origin: String) throws {
        guard var manifest, let paths = sessionPaths else { return }
        manifest.updatedAt = Date()
        manifest.lastPageIndex = currentPageIndex
        self.manifest = manifest
        try repository.saveState(
            manifest: manifest,
            highlights: highlights,
            comments: comments,
            notes: notes,
            paths: paths
        )
        try repository.appendEvent(
            SessionEvent(
                sessionID: manifest.id,
                actor: "user",
                origin: origin,
                kind: eventKind,
                recordID: recordID
            ),
            to: paths.eventLog
        )
        scheduleAnnotatedPDFExport()
    }

    /// Regenerates `<paper>-annotated.pdf` off the main thread, a second after
    /// the last change to a highlight, comment, or agent reply. Position saves
    /// and notes autosaves do not trigger it: the signature covers only what
    /// the copy actually embeds.
    func scheduleAnnotatedPDFExport() {
        guard let manifest, let paths = sessionPaths, let sourceURL else { return }
        var parts: [String] = []
        for highlight in highlights {
            parts.append("\(highlight.id):\(highlight.color):\(highlight.deletedAt?.timeIntervalSince1970 ?? 0)")
        }
        for comment in comments {
            parts.append("\(comment.id):\(comment.status):\(comment.updatedAt.timeIntervalSince1970)")
        }
        for id in agentReplies.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            parts.append("\(id):\(agentReplies[id]?.hashValue ?? 0)")
        }
        let signature = parts.joined(separator: "|")
        guard signature != annotatedPDFSignature else { return }
        annotatedPDFSignature = signature

        let highlights = self.highlights
        let comments = self.comments
        let replies = self.agentReplies
        let destination = paths.annotatedPDF(for: manifest)
        annotatedPDFTask?.cancel()
        annotatedPDFTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result {
                    try AnnotatedPDFExporter.write(
                        sourceURL: sourceURL,
                        to: destination,
                        highlights: highlights,
                        comments: comments,
                        replies: replies
                    )
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            if case .failure(let error) = result {
                // Not worth an alert mid-reading; the sidecar records are intact.
                self.statusMessage = "Annotated PDF not updated: \(error.localizedDescription)"
                self.annotatedPDFSignature = ""
            }
        }
    }

    private func persistStateWithoutEvent() throws {
        guard var manifest, let paths = sessionPaths else { return }
        manifest.updatedAt = Date()
        manifest.lastPageIndex = currentPageIndex
        self.manifest = manifest
        try repository.saveState(
            manifest: manifest,
            highlights: highlights,
            comments: comments,
            notes: notes,
            paths: paths
        )
    }

    private func schedulePagePositionSave() {
        pageSaveTask?.cancel()
        pageSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            try? self.persistStateWithoutEvent()
        }
    }

    private func writeSelectionContext(_ snapshot: SelectionSnapshot?, activeHighlightID: UUID?) throws {
        guard let manifest else { return }
        let pageIndex = snapshot?.primaryPageIndex ?? currentPageIndex
        let pageLabel = snapshot?.primaryPageLabel ?? currentPageLabel
        let context = CurrentContext(
            sessionID: manifest.id,
            sourcePDFPath: manifest.sourcePDFPath,
            sourcePDFFingerprint: manifest.sourcePDFFingerprint,
            pageIndex: pageIndex,
            pageLabel: pageLabel,
            selectedText: snapshot?.selectedText,
            prefix: snapshot?.prefix ?? boundedPageText(currentPageText),
            suffix: snapshot?.suffix ?? "",
            activeHighlightID: activeHighlightID,
            textStatus: snapshot == nil ? (currentPageText.isEmpty ? "unavailable" : "page_excerpt") : "selection",
            readingMode: manifest.readingMode,
            furthestPageIndex: manifest.furthestPageIndex
        )
        try writeContext(context)
    }

    private func writePageContext() throws {
        try writeSelectionContext(nil, activeHighlightID: selectedHighlightID)
    }

    private func writeContext(_ context: CurrentContext) throws {
        guard let paths = sessionPaths else { return }
        // A direct write supersedes whatever a drag or scroll had queued.
        contextWriteTask?.cancel()
        try repository.writeCurrentContext(context, paths: paths)
        currentContextPreview = MarkdownExporter.renderCurrentContext(context)
    }

    private func extractText(from document: PDFDocument) -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let label = document.page(at: index)?.label ?? String(index + 1)
            let text = document.page(at: index)?.string ?? "[No extractable text on this page]"
            pages.append("--- Page \(label) (index \(index)) ---\n\(text)")
        }
        return pages.joined(separator: "\n\n") + "\n"
    }

    private func documentTitle(document: PDFDocument, url: URL) -> String {
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func boundedPageText(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(1_500))
    }

    private func sanitizedFilename(_ value: String) -> String {
        let result = value
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "paper" : result
    }

    private func selectionSignature(_ snapshot: SelectionSnapshot) -> String {
        let geometry = snapshot.locations.flatMap { location in
            location.lineRects.map {
                "\(location.pageIndex):\($0.x):\($0.y):\($0.width):\($0.height)"
            }
        }.joined(separator: "|")
        return snapshot.selectedText.normalizedForSearch + "|" + geometry
    }
}
