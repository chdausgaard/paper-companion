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

    private let repository = SessionRepository()
    private var currentPageText = ""
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
            let loaded = try repository.createOrLoadSession(
                pdfURL: url,
                title: title,
                pageCount: pdfDocument.pageCount,
                extractedText: extractedText
            )
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
            currentPageIndex = min(loaded.manifest.lastPageIndex, max(0, pdfDocument.pageCount - 1))
            currentPageLabel = pdfDocument.page(at: currentPageIndex)?.label ?? String(currentPageIndex + 1)
            currentPageText = pdfDocument.page(at: currentPageIndex)?.string ?? ""
            navigationPageIndex = currentPageIndex
            navigationHighlightID = nil
            navigationRequestID = UUID()
            statusMessage = "Session ready · \(pdfDocument.pageCount) pages"
            refreshAgentFiles()
            try writePageContext()
        } catch {
            errorMessage = "Could not create the reading session: \(error.localizedDescription)"
        }
    }

    func selectionChanged(_ snapshot: SelectionSnapshot?, allowAutoHighlight: Bool = true) {
        autoHighlightTask?.cancel()
        currentSelection = snapshot
        selectedHighlightID = nil
        if snapshot == nil { lastAutoHighlightSignature = nil }
        if let pageIndex = snapshot?.primaryPageIndex {
            currentPageIndex = pageIndex
            currentPageLabel = snapshot?.primaryPageLabel ?? String(pageIndex + 1)
        }
        do {
            try writeSelectionContext(snapshot, activeHighlightID: nil)
            statusMessage = snapshot == nil ? "Selection cleared" : "Selection ready for highlighting or agent context"
        } catch {
            errorMessage = "Could not update agent context: \(error.localizedDescription)"
        }

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
        if currentSelection == nil {
            do {
                try writePageContext()
            } catch {
                errorMessage = "Could not update page context: \(error.localizedDescription)"
            }
        }
        schedulePagePositionSave()
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

    /// A margin note: anchored like any other comment, but journalled so the
    /// agent records it without responding. Links to the current selection or
    /// highlight when there is one, so the anchor is not lost.
    func addQuickNote() {
        let hasAnchor = selectedHighlight != nil || currentSelection != nil
        addComment(linkToHighlight: hasAnchor, kind: .quiet)
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
                self.statusMessage = "Notes autosaved"
            } catch {
                self.errorMessage = "Could not autosave notes: \(error.localizedDescription)"
            }
        }
    }

    func deleteHighlight(_ id: UUID) {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        applyHighlightDeletion(id, deletedAt: Date(), actionName: "Remove Highlight")
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

    private func applyHighlightDeletion(_ id: UUID, deletedAt: Date?, actionName: String) {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              highlights[index].deletedAt != deletedAt else { return }
        let previousDeletedAt = highlights[index].deletedAt
        undoManager.registerUndo(withTarget: self) { target in
            target.applyHighlightDeletion(id, deletedAt: previousDeletedAt, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        highlights[index].deletedAt = deletedAt
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
                : "Highlight removed; linked comments were retained · ⌘Z to undo"
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

    func selectHighlight(_ highlight: HighlightRecord) {
        selectedHighlightID = highlight.id
        navigationPageIndex = highlight.pageIndex
        navigationHighlightID = highlight.id
        navigationRequestID = UUID()
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
                textStatus: "highlight"
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
        guard let pageIndex = comment.pageIndex else { return }
        navigationPageIndex = pageIndex
        navigationHighlightID = nil
        navigationRequestID = UUID()
        statusMessage = "Page-only comment · page \(comment.pageLabel ?? String(pageIndex + 1))"
    }

    func requestSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchRequestID = UUID()
    }

    func revealSessionFolder() {
        guard let root = sessionPaths?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func copyAgentPrompt() {
        guard let root = sessionPaths?.root else { return }
        let prompt = "Use the active Paper Companion reading session at \(root.path). Read its AGENTS.md and current context, then capture my comments as we go."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        statusMessage = "Agent prompt copied"
    }

    func refreshAgentFiles() {
        guard let paths = sessionPaths else { return }
        currentContextPreview = (try? String(contentsOf: paths.currentContextMarkdown, encoding: .utf8)) ?? "No current context yet."
        sharedUnderstandingPreview = (try? String(contentsOf: paths.sharedUnderstanding, encoding: .utf8)) ?? "No shared understanding yet."
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
            textStatus: snapshot == nil ? (currentPageText.isEmpty ? "unavailable" : "page_excerpt") : "selection"
        )
        try writeContext(context)
    }

    private func writePageContext() throws {
        try writeSelectionContext(nil, activeHighlightID: selectedHighlightID)
    }

    private func writeContext(_ context: CurrentContext) throws {
        guard let paths = sessionPaths else { return }
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
