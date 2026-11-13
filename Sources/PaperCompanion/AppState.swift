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
    /// Set when a newly made highlight should hand the keyboard to the comment
    /// box. One composer takes it, through `takeCommentFocusRequest()`, so a
    /// composer created later by the tab switch still sees it.
    @Published private(set) var commentFocusRequestID: UUID?
    private var commentFocusRequestedAt = Date.distantPast
    private var commentFocusHighlightID: UUID?
    private var takenCommentFocusRequestID: UUID?
    /// Filters the annotations list; matching is `AnnotationSearch`.
    @Published var annotationSearchQuery = ""
    /// Set by Find in Comments (⇧⌘F); the sidebar search field takes it once.
    @Published private(set) var annotationSearchFocusRequestID: UUID?
    private var annotationSearchFocusRequestedAt = Date.distantPast
    private var takenAnnotationSearchFocusRequestID: UUID?
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

    /// Comment on Region (⇧⌘R): while on, a drag on a page draws a box to
    /// comment on instead of selecting text. It turns itself off after one
    /// box, on Esc, and when the document changes.
    @Published var regionToolActive = false {
        didSet {
            guard regionToolActive != oldValue, regionToolActive else { return }
            // Armed with no reader on screen, Esc would have nothing to
            // cancel it and the reader would come back armed.
            guard canUseRegionTool else {
                regionToolActive = false
                return
            }
            statusMessage = "Drag a box over a figure, table or any area to comment on it · Esc cancels"
        }
    }
    /// The PDF reader is in a window (not replaced by the library, its
    /// window not closed). Reported by the reader itself.
    @Published private(set) var readerOnScreen = false

    /// The region tool needs a paper and the reader showing it.
    var canUseRegionTool: Bool { document != nil && readerOnScreen }

    func readerOnScreenChanged(_ onScreen: Bool) {
        guard readerOnScreen != onScreen else { return }
        readerOnScreen = onScreen
        if !onScreen, regionToolActive { regionToolActive = false }
    }
    /// The color a new region gets, like a new highlight's.
    static let newRegionColor = HighlightColor.yellow

    /// Every app action is its own undo group (`registerUndoStep`), never
    /// one folded together by event, so a failed undo or redo always concerns
    /// exactly one action and can be put back whole.
    var undoManager = AppState.makeUndoManager() {
        didSet { undoManager.groupsByEvent = false }
    }

    static func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }
    /// Pointer hover linking the PDF page and the cards. Deliberately not
    /// `@Published`: see `AnnotationHover`.
    let annotationHover = AnnotationHover()

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
            pendingUndoBounces.removeAll()
            regionToolActive = false
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
            annotationSearchQuery = ""
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
            _ = self.createHighlight(from: currentSelection, origin: "auto_highlight", registerUndo: true, focusComposer: true)
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
        _ = createHighlight(from: snapshot, origin: "pdf_selection", registerUndo: true, focusComposer: true)
    }

    /// `focusComposer` scrolls the new card into view and puts the cursor in
    /// the comment box once the highlight exists. Only a highlight the user
    /// just made asks for it: not one that already existed, and not the anchor
    /// a saved comment creates (its search check would run before the comment
    /// exists).
    @discardableResult
    private func createHighlight(
        from snapshot: SelectionSnapshot,
        origin: String,
        registerUndo: Bool,
        focusComposer: Bool = false
    ) -> HighlightRecord? {
        if let existing = activeHighlights.last(where: {
            !$0.isRegion && $0.quote == snapshot.selectedText && $0.locations == snapshot.locations
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
        let previousSelection = (highlight: selectedHighlightID, comment: selectedCommentID)
        highlights.append(highlight)
        selectedHighlightID = highlight.id
        selectedCommentID = nil
        do {
            try persistState(eventKind: "highlight_created", recordID: highlight.id, origin: origin)
        } catch {
            // Not saved: it never happened, in memory or in the files.
            highlights.removeAll { $0.id == highlight.id }
            selectedHighlightID = previousSelection.highlight
            selectedCommentID = previousSelection.comment
            errorMessage = "Could not save the highlight: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            return nil
        }
        // Saved and journalled: from here on it exists, and ⌘Z removes it.
        var contextError: Error?
        do {
            try writeSelectionContext(snapshot, activeHighlightID: highlight.id)
        } catch {
            contextError = error
        }
        if registerUndo { registerUndoForCreatedHighlight(highlight.id, actionName: "Highlight") }
        statusMessage = "Highlight saved · page \(highlight.pageLabel)"
        if focusComposer {
            revealInSidebar(highlight.id)
            requestCommentFocus()
        }
        if let contextError {
            errorMessage = "The highlight was saved, but the agent’s current context could not be updated: \(contextError.localizedDescription)"
        }
        return highlight
    }

    // MARK: Regions

    /// The region tool ended without a box (Esc, or the reader left).
    func regionToolCancelled() {
        guard regionToolActive else { return }
        regionToolActive = false
        statusMessage = "Comment on Region cancelled"
    }

    /// A box drawn with the region tool. The tool is one-shot: it is off
    /// whether or not the box is kept.
    @discardableResult
    func regionDrawn(on page: PDFPage, rect: CGRect) -> HighlightRecord? {
        regionToolActive = false
        return createRegion(on: page, rect: rect)
    }

    /// Saves a box on `page` (page space) as a region: its two pictures for
    /// the agent first, then the record. A region whose pictures could not be
    /// written is not created, because the agent could not see what it is
    /// about. Selects it and puts the cursor in the comment box, like a new
    /// highlight.
    @discardableResult
    func createRegion(on page: PDFPage, rect: CGRect) -> HighlightRecord? {
        guard let document, page.document === document else { return nil }
        guard let record = RegionSnapshot.makeRecord(page: page, rect: rect, color: Self.newRegionColor.rawValue) else {
            statusMessage = "No region saved: the box was too small · ⇧⌘R to draw another"
            return nil
        }
        if let existing = activeHighlights.last(where: { $0.isRegion && $0.locations == record.locations }) {
            selectHighlight(existing, navigate: false)
            revealInSidebar(existing.id)
            statusMessage = "This box is already a region · page \(existing.pageLabel)"
            return existing
        }
        guard let paths = sessionPaths else {
            errorMessage = "Could not save the region: no reading session is open."
            return nil
        }
        do {
            try RegionSnapshot.writeImages(for: record, page: page, paths: paths)
        } catch {
            errorMessage = "Could not save the region: its pictures for the agent could not be written to the session’s regions folder (\(error.localizedDescription)). Nothing was added; draw the box again once the folder can be written."
            statusMessage = "Region not saved"
            return nil
        }
        highlights.append(record)
        selectedHighlightID = record.id
        selectedCommentID = nil
        do {
            try persistState(eventKind: "region_created", recordID: record.id, origin: "region_tool")
        } catch {
            // Not saved: take it back out of memory, and out of the files too,
            // in case the records were written and only the journal failed,
            // so the agent never sees a region the reader does not.
            highlights.removeAll { $0.id == record.id }
            if selectedHighlightID == record.id { selectedHighlightID = nil }
            errorMessage = "Could not save the region: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            return nil
        }
        // Saved: from here on the region exists, on disk and on screen, and
        // ⌘Z is what removes it.
        registerUndoForCreatedHighlight(record.id, actionName: "Region")
        statusMessage = "Region saved · page \(record.pageLabel) · type a comment, or leave it for later"
        revealInSidebar(record.id)
        requestCommentFocus()
        do {
            try writeContext(anchorContext(for: record))
        } catch {
            errorMessage = "The region was saved, but the agent’s current context could not be updated: \(error.localizedDescription)"
        }
        return record
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
                if linkedHighlight == nil {
                    statusMessage = "Page-only comment saved · visible under Saved comments"
                } else if linkedHighlight?.isRegion == true {
                    statusMessage = "Comment linked to the region · visible under Saved comments"
                } else {
                    statusMessage = "Comment linked to highlighted text · visible under Saved comments"
                }
            }
        } catch {
            // Not saved: out of memory and out of the files, so the agent
            // cannot answer a comment the user was told was not saved. The
            // draft is kept. An anchor highlight made for it above was saved
            // and journalled on its own, so it stays.
            comments.removeAll { $0.id == comment.id }
            errorMessage = "Could not save the comment: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
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
    /// Returns false only when the new text could not be saved, so the
    /// editor can stay open with it; true when it was saved or there was
    /// nothing to save.
    @discardableResult
    func updateComment(_ id: UUID, verbatim: String) -> Bool {
        let text = verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = comments.firstIndex(where: { $0.id == id }),
              !text.isEmpty,
              comments[index].verbatim != text else { return true }
        let previous = comments[index].verbatim
        let previousUpdatedAt = comments[index].updatedAt
        comments[index].verbatim = text
        comments[index].updatedAt = Date()
        do {
            try persistState(eventKind: "comment_updated", recordID: id, origin: "typed")
        } catch {
            // Not saved: the comment keeps its saved text everywhere, and
            // there is no edit to undo.
            comments[index].verbatim = previous
            comments[index].updatedAt = previousUpdatedAt
            errorMessage = "Could not update the comment: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            undoStepFailed = true
            return false
        }
        registerUndoStep("Edit Comment") { target in
            if target.updateComment(id, verbatim: previous) {
                target.comments[index].updatedAt = previousUpdatedAt
            }
        }
        statusMessage = "Comment updated"
        return true
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
        applyHighlightDeletion(id, deletedAt: Date(), actionName: isRegion(id) ? "Remove Region" : "Remove Highlight")
    }

    private func isRegion(_ id: UUID) -> Bool {
        highlights.first { $0.id == id }?.isRegion ?? false
    }

    func setHighlightColor(_ id: UUID, color: String) {
        guard HighlightColor(rawValue: color) != nil,
              let index = highlights.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              highlights[index].color != color else { return }
        let previous = highlights[index].color
        highlights[index].color = color
        let region = highlights[index].isRegion
        let actionName = region ? "Change Region Color" : "Change Highlight Color"
        do {
            try persistState(eventKind: region ? "region_color_changed" : "highlight_color_changed", recordID: id, origin: "app_action")
            registerUndoStep(actionName) { $0.setHighlightColor(id, color: previous) }
        } catch {
            highlights[index].color = previous
            // The records may have been written before the journal failed:
            // write them back as they are now, so the files match the page.
            errorMessage = "Could not save the highlight color: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            undoStepFailed = true
        }
    }

    func deleteSelectedHighlight() {
        guard let selectedHighlightID else { return }
        deleteHighlight(selectedHighlightID)
    }

    private func registerUndoForCreatedHighlight(_ id: UUID, actionName: String) {
        registerUndoStep(actionName) { target in
            target.applyHighlightDeletion(id, deletedAt: Date(), actionName: actionName)
        }
    }

    private func applyHighlightDeletion(_ id: UUID, deletedAt: Date?, actionName: String, restoringComments: [CommentRecord]? = nil) {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              highlights[index].deletedAt != deletedAt else { return }
        let previousDeletedAt = highlights[index].deletedAt
        let previousComments = comments.filter { $0.highlightID == id }
        let before = (highlights: highlights, comments: comments, selectedHighlightID: selectedHighlightID)
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
        let restored = deletedAt == nil
        let region = highlights[index].isRegion
        let origin: String
        if undoManager.isUndoing {
            origin = "undo"
        } else if undoManager.isRedoing {
            origin = "redo"
        } else {
            origin = "app_action"
        }
        let noun = region ? "region" : "highlight"
        do {
            try persistState(
                eventKind: restored ? "\(noun)_restored" : "\(noun)_deleted",
                recordID: id,
                origin: origin
            )
        } catch {
            // Not saved: the highlight and its comments stay as they were,
            // in memory and in the files, and there is nothing to undo.
            highlights = before.highlights
            comments = before.comments
            selectedHighlightID = before.selectedHighlightID
            errorMessage = "Could not update the highlight: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            undoStepFailed = true
            return
        }
        // Saved and journalled: it happened, and ⌘Z reverses it.
        registerUndoStep(actionName) { target in
            target.applyHighlightDeletion(id, deletedAt: previousDeletedAt, actionName: actionName, restoringComments: previousComments)
        }
        do {
            try writePageContext()
        } catch {
            errorMessage = "The \(noun) was \(restored ? "restored" : "removed"), but the agent’s current context could not be updated: \(error.localizedDescription)"
        }
        statusMessage = restored
            ? (region ? "Region restored" : "Highlight restored")
            : (region ? "Region and linked comments removed · ⌘Z to undo" : "Highlight and linked comments removed · ⌘Z to undo")
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
        comments[index].status = status
        comments[index].updatedAt = updatedAt

        let restored = status != "deleted"
        do {
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
        } catch {
            // Not saved: the comment stays as it was, in memory and in the
            // files the agent watches, and there is nothing to undo.
            comments[index].status = previousStatus
            comments[index].updatedAt = previousUpdatedAt
            errorMessage = "Could not update the comment: \(error.localizedDescription)" + rewriteFilesAfterFailedSave()
            undoStepFailed = true
            return
        }
        registerUndoStep(actionName) { target in
            target.applyCommentState(
                id,
                status: previousStatus,
                updatedAt: previousUpdatedAt,
                actionName: actionName
            )
        }
        statusMessage = restored
            ? "Comment restored"
            : "Comment deleted · ⌘Z to undo"
    }

    func performUndo() {
        if let textUndoManager = focusedTextUndoManager, textUndoManager.canUndo {
            textUndoManager.undo()
        } else {
            // A recovery still pending from an undo started elsewhere comes
            // first, so this undo takes the entry the user sees.
            completePendingUndoBounces()
            guard undoManager.canUndo else { return }
            undoManager.undo()
            completePendingUndoBounces()
        }
    }

    func performRedo() {
        if let textUndoManager = focusedTextUndoManager, textUndoManager.canRedo {
            textUndoManager.redo()
        } else {
            completePendingUndoBounces()
            guard undoManager.canRedo else { return }
            undoManager.redo()
            completePendingUndoBounces()
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
            try writeContext(anchorContext(for: highlight))
            statusMessage = highlight.isRegion
                ? "Active region · page \(highlight.pageLabel)"
                : "Active highlight · page \(highlight.pageLabel)"
        } catch {
            errorMessage = "Could not activate the highlight context: \(error.localizedDescription)"
        }
    }

    /// The agent's context with a highlight or a region as the active
    /// anchor. A region has no quote: the context names it as a region and
    /// carries where its pictures are instead.
    private func anchorContext(for highlight: HighlightRecord) -> CurrentContext {
        CurrentContext(
            sessionID: manifest?.id ?? UUID(),
            sourcePDFPath: manifest?.sourcePDFPath ?? "",
            sourcePDFFingerprint: manifest?.sourcePDFFingerprint ?? "",
            pageIndex: highlight.pageIndex,
            pageLabel: highlight.pageLabel,
            selectedText: highlight.isRegion ? nil : highlight.quote,
            prefix: highlight.prefix,
            suffix: highlight.suffix,
            activeHighlightID: highlight.id,
            textStatus: highlight.isRegion ? "region" : "highlight",
            readingMode: manifest?.readingMode ?? .preread,
            furthestPageIndex: manifest?.furthestPageIndex ?? highlight.pageIndex,
            activeRegion: highlight.isRegion ? highlight.region : nil
        )
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
            // A comment whose deletion could not be saved is still there,
            // and stays selected.
            if !comments.contains(where: { $0.id == selectedCommentID && $0.status != "deleted" }) {
                self.selectedCommentID = nil
            }
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
        revealInSidebar(id)
    }

    /// Scrolls an entry's card into view. A search that hides the card would
    /// leave nothing to reveal, so it is cleared first.
    private func revealInSidebar(_ id: UUID) {
        if AnnotationSearch.isActive(annotationSearchQuery),
           let entry = annotationEntries.first(where: { $0.id == id }),
           !AnnotationSearch.matches(entry, query: annotationSearchQuery) {
            annotationSearchQuery = ""
        }
        sidebarRevealID = id
        sidebarRevealRequestID = UUID()
    }

    /// Requests are honoured for a short while only, so a composer created
    /// much later (say, after returning from the library) does not grab the
    /// keyboard for a highlight made long ago.
    static let focusRequestLifetime: TimeInterval = 2

    func requestCommentFocus() {
        inspectorTab = .annotations
        commentFocusRequestedAt = Date()
        commentFocusHighlightID = selectedHighlightID
        commentFocusRequestID = UUID()
    }

    /// Claims the pending request for one composer: returns its ID once, then
    /// nil. The composer checks `isCommentFocusRequestCurrent` again at the
    /// moment it actually takes focus.
    func takeCommentFocusRequest() -> UUID? {
        guard let id = commentFocusRequestID,
              id != takenCommentFocusRequestID,
              isCommentFocusRequestCurrent(id) else { return nil }
        takenCommentFocusRequestID = id
        return id
    }

    /// Still the latest request, still young, and the highlight it was made
    /// for is still the selected one.
    func isCommentFocusRequestCurrent(_ id: UUID) -> Bool {
        id == commentFocusRequestID
            && Date().timeIntervalSince(commentFocusRequestedAt) < Self.focusRequestLifetime
            && selectedHighlightID == commentFocusHighlightID
    }

    /// Find in Comments (⇧⌘F).
    func findInComments() {
        guard document != nil else { return }
        inspectorTab = .annotations
        annotationSearchFocusRequestedAt = Date()
        annotationSearchFocusRequestID = UUID()
    }

    func takeAnnotationSearchFocusRequest() -> UUID? {
        guard let id = annotationSearchFocusRequestID,
              id != takenAnnotationSearchFocusRequestID,
              isAnnotationSearchFocusRequestCurrent(id) else { return nil }
        takenAnnotationSearchFocusRequestID = id
        return id
    }

    func isAnnotationSearchFocusRequestCurrent(_ id: UUID) -> Bool {
        id == annotationSearchFocusRequestID
            && Date().timeIntervalSince(annotationSearchFocusRequestedAt) < Self.focusRequestLifetime
    }

    /// Esc in an empty comment box hands the keyboard back to the PDF.
    func requestPDFFocus() {
        pdfFocusRequestID = UUID()
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
        // Kept equal to what `saveState` writes for these records.
        manifest.schemaVersion = SessionRepository.schemaVersion(for: highlights)
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
        manifest.schemaVersion = SessionRepository.schemaVersion(for: highlights)
        self.manifest = manifest
        try repository.saveState(
            manifest: manifest,
            highlights: highlights,
            comments: comments,
            notes: notes,
            paths: paths
        )
    }

    /// After a save that failed, once the caller has put memory back: writes
    /// the records again to match it, in case they reached disk and only the
    /// journal failed, so the agent never acts on something the user was told
    /// did not happen. Returns what to add to the error when this write fails
    /// too, so that is reported rather than hidden.
    private func rewriteFilesAfterFailedSave() -> String {
        do {
            try persistStateWithoutEvent()
            return ""
        } catch {
            return " The session files could not be put back to match either (\(error.localizedDescription)); they may show the change until the next successful save."
        }
    }

    // MARK: Undo steps

    /// Set by an action whose save failed, so the undo step that ran it knows
    /// to put itself back (`undoStep`). Reset before every step.
    private var undoStepFailed = false

    /// Registers `action` as the undo (or, while undoing, the redo) of what
    /// was just done, as one group of its own.
    private func registerUndoStep(_ actionName: String, _ action: @escaping (AppState) -> Void) {
        let manager = undoManager
        let step = Self.undoStep(actionName, action)
        if manager.isUndoing || manager.isRedoing {
            // Inside the group the manager opened for the undo or redo.
            manager.registerUndo(withTarget: self, handler: step)
            manager.setActionName(actionName)
        } else {
            manager.beginUndoGrouping()
            manager.registerUndo(withTarget: self, handler: step)
            manager.setActionName(actionName)
            manager.endUndoGrouping()
        }
    }

    /// An undo entry that runs `action` and, if its save failed, puts this
    /// same entry back where it came from, unchanged: a failed undo or redo
    /// changed nothing, so both stacks must end as they were.
    private static func undoStep(_ actionName: String, _ action: @escaping (AppState) -> Void) -> (AppState) -> Void {
        { target in
            target.undoStepFailed = false
            action(target)
            guard target.undoStepFailed else { return }
            target.undoStepFailed = false
            target.putBackUndoStep(undoStep(actionName, action), named: actionName)
        }
    }

    private enum UndoBounce { case undo, redo }
    /// Recoveries not yet completed, newest last. More than one is pending
    /// only when undos are started without `performUndo`.
    private var pendingUndoBounces: [(manager: UndoManager, step: UndoBounce, token: String)] = []

    /// The manager has already taken the failed entry off its stack, and a
    /// plain registration would put it back only by clearing the other stack.
    /// So a one-off "bounce" entry goes on the opposite stack (where
    /// registrations land during an undo or redo) and is performed as soon
    /// as the undo or redo returns: performing it is itself a redo (or undo),
    /// during which the entry is registered again on the stack it came from
    /// without touching the other one.
    private func putBackUndoStep(_ step: @escaping (AppState) -> Void, named actionName: String) {
        let manager = undoManager
        guard manager.isUndoing || manager.isRedoing else { return }
        let direction: UndoBounce = manager.isUndoing ? .redo : .undo
        manager.registerUndo(withTarget: self) { target in
            manager.registerUndo(withTarget: target, handler: step)
            manager.setActionName(actionName)
        }
        // A name no real action has, so a bounce is performed only while it
        // is the top entry. Never shown: it is gone before the menu is read.
        let token = "Paper Companion undo bounce \(UUID().uuidString)"
        manager.setActionName(token)
        pendingUndoBounces.append((manager, direction, token))
        // `performUndo` and `performRedo` complete it at once; this covers an
        // undo started some other way.
        Task { @MainActor [weak self] in self?.completePendingUndoBounces() }
    }

    /// Newest first: each bounce is then the top of its stack, and the
    /// entries go back in their original order.
    private func completePendingUndoBounces() {
        while let (manager, step, token) = pendingUndoBounces.last {
            guard !manager.isUndoing, !manager.isRedoing else { return }
            pendingUndoBounces.removeLast()
            switch step {
            case .redo: if manager.canRedo, manager.redoActionName == token { manager.redo() }
            case .undo: if manager.canUndo, manager.undoActionName == token { manager.undo() }
            }
        }
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
        // A selected region stays the active anchor while the reader scrolls:
        // a comment saved now links to it, so the agent is told about it.
        if snapshot == nil, let activeHighlightID,
           let region = activeHighlights.first(where: { $0.id == activeHighlightID && $0.isRegion }) {
            try writeContext(anchorContext(for: region))
            return
        }
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
