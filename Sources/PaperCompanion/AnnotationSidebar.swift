import AppKit
import ImageIO
import PaperCompanionCore
import SwiftUI

// MARK: - Annotations

/// Highlights and comments as one list in paper order, with the composer
/// underneath. One selected entry is expanded to full text and tinted in the
/// PDF; clicking a highlight in the PDF selects its entry here.
struct AnnotationsView: View {
    var body: some View {
        VSplitView {
            AnnotationList()
                .frame(minHeight: 200, idealHeight: 460)
            CommentComposer()
                .frame(minHeight: 150, idealHeight: 210)
        }
    }
}

struct AnnotationList: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = state.annotationEntries
        let query = state.annotationSearchQuery
        let searching = AnnotationSearch.isActive(query)
        let visible = AnnotationSearch.filter(entries, query: query)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(searching ? "\(visible.count) of \(entries.count)" : summary(entries))
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                if state.selectedEntryID != nil {
                    Button("Deselect", action: state.clearEntrySelection)
                        .controlSize(.small)
                        .help("Collapse the selected annotation (Esc)")
                }
            }
            .frame(minHeight: 20)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            CommentSearchField(
                text: $state.annotationSearchQuery,
                isEnabled: !entries.isEmpty || searching,
                focusRequestID: state.annotationSearchFocusRequestID,
                takeFocusRequest: state.takeAnnotationSearchFocusRequest,
                isFocusRequestCurrent: { [weak state] id in state?.isAnnotationSearchFocusRequestCurrent(id) ?? false }
            )
            .help("Search your comments, and the text of highlights without one (⇧⌘F)")
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // The scroll view stays in place even when nothing is listed, so a
            // reveal request that also clears the search still finds it.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(AnnotationEntry.groupedByPage(visible)) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    AnnotationCard(
                                        entry: entry,
                                        expanded: state.selectedEntryID == entry.id,
                                        query: query
                                    )
                                    .id(entry.id)
                                }
                            } header: {
                                PageGroupHeader(label: group.pageLabel)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                    .animation(InteractionStyle.expand(reduceMotion: reduceMotion), value: state.selectedEntryID)
                }
                .overlay {
                    if entries.isEmpty {
                        emptyState
                    } else if visible.isEmpty {
                        noMatchState(query)
                    }
                }
                .onChange(of: state.sidebarRevealRequestID) { _ in
                    guard let id = state.sidebarRevealID else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(
            // While the region tool is on, Esc belongs to it: it turns the
            // tool off and does nothing else (`HighlightClickPDFView`).
            EscapeKeyMonitor(isEnabled: state.selectedEntryID != nil && !state.regionToolActive) {
                state.clearEntrySelection()
            }
        )
    }

    private var emptyState: some View {
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
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noMatchState(_ query: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No comments match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Search looks at your comments, and at what a card without one shows: the highlighted text, or a region’s caption.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Search") { state.annotationSearchQuery = "" }
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ entries: [AnnotationEntry]) -> String {
        let regions = entries.filter { $0.highlight?.isRegion == true }.count
        let highlights = entries.filter { $0.highlight != nil }.count - regions
        let comments = entries.reduce(0) { $0 + $1.comments.count }
        let replies = state.agentReplies.keys.filter { id in
            entries.contains { $0.comments.contains { $0.id == id } }
        }.count
        var parts = ["\(highlights) highlight\(highlights == 1 ? "" : "s")"]
        if regions > 0 { parts.append("\(regions) region\(regions == 1 ? "" : "s")") }
        parts.append("\(comments) comment\(comments == 1 ? "" : "s")")
        if replies > 0 { parts.append("\(replies) repl\(replies == 1 ? "y" : "ies")") }
        return parts.joined(separator: " · ")
    }
}

/// The pinned "Page 4" header above a page's cards. Opaque, so cards scroll
/// under it cleanly. The inspector's tab box tints its content by about 3% of
/// the label color; the header repeats that tint so it does not read as a band.
struct PageGroupHeader: View {
    let label: String

    var body: some View {
        Text("Page \(label)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Color.primary.opacity(0.03)
                }
            )
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Anchor markers

/// What a card is attached to, shown as a small leading marker.
enum AnchorMarker: Equatable {
    /// A comment on highlighted text, or a highlight with no comment yet.
    case highlight(HighlightColor)
    /// A page-level comment (also a comment whose highlight was removed).
    case page
    /// A box drawn on the page: a thumbnail of what it holds.
    case region(HighlightRecord)

    init(entry: AnnotationEntry) {
        if let highlight = entry.highlight {
            self = highlight.isRegion ? .region(highlight) : .highlight(HighlightColor(rawValue: highlight.color) ?? .yellow)
        } else {
            self = .page
        }
    }

    var helpText: String {
        switch self {
        case .highlight: return "Attached to highlighted text"
        case .page: return "Attached to the page"
        case .region: return "Attached to a boxed area of the page"
        }
    }
}

struct AnchorMarkerView: View {
    let marker: AnchorMarker
    /// Width of the leading marker column on cards.
    static let columnWidth: CGFloat = 14
    /// A region's thumbnail is wider than the column: a picture smaller than
    /// this does not show which figure it is.
    static let regionThumbnailSize = CGSize(width: 34, height: 26)

    var body: some View {
        Group {
            switch marker {
            case .region(let highlight):
                RegionThumbnail(highlight: highlight, size: Self.regionThumbnailSize)
            case .highlight(let color):
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: color.nsColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                    )
                    .frame(width: 10, height: 10)
            case .page:
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .help(marker.helpText)
        .accessibilityLabel(marker.helpText)
    }

    private var frameSize: CGSize {
        if case .region = marker { return Self.regionThumbnailSize }
        return CGSize(width: Self.columnWidth, height: 14)
    }
}

// MARK: - Region pictures

/// Region pictures for the sidebar. The files are found, read and scaled
/// down to the size shown off the main thread (ImageIO makes the small
/// picture straight from the file without decoding it whole), then kept: a
/// bounded cache of results, and a list of pictures found missing so a
/// missing file is not looked for again. The files are written once when a
/// region is drawn and never change, so nothing kept goes stale.
@MainActor
enum RegionImageCache {
    enum Entry {
        case image(NSImage)
        /// No picture file (a folder removed or emptied by hand).
        case missing
    }

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        // Pixels × 4 bytes; a few hundred thumbnails and a dozen previews.
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static var missing: Set<String> = []
    /// Loads under way. They hand back nothing: the result goes into the
    /// cache, where every caller waiting on the load reads it.
    private static var loads: [String: Task<Void, Never>] = [:]
    /// Loads finished, and whether any is under way: for tests that wait
    /// for the pictures.
    private(set) static var finishedLoads = 0
    static var isLoading: Bool { !loads.isEmpty }

    static func key(for highlight: HighlightRecord, paths: SessionPaths?, maxPixels: Int) -> String {
        "\(paths?.root.path ?? "-")|\(highlight.id.uuidString)|\(maxPixels)"
    }

    /// What is known without touching the disk; nil when not loaded yet.
    static func cached(for highlight: HighlightRecord, paths: SessionPaths?, maxPixels: Int) -> Entry? {
        guard highlight.isRegion, paths != nil else { return .missing }
        let key = key(for: highlight, paths: paths, maxPixels: maxPixels)
        if let image = images.object(forKey: key as NSString) { return .image(image) }
        return missing.contains(key) ? .missing : nil
    }

    /// Loads the picture once; callers asking for the same one meanwhile
    /// share the load.
    static func load(for highlight: HighlightRecord, paths: SessionPaths?, maxPixels: Int) async -> Entry {
        if let known = cached(for: highlight, paths: paths, maxPixels: maxPixels) { return known }
        guard let paths else { return .missing }
        let key = key(for: highlight, paths: paths, maxPixels: maxPixels)
        let task: Task<Void, Never>
        if let running = loads[key] {
            task = running
        } else {
            task = Task { @MainActor in
                let picture = await Task.detached(priority: .utility) {
                    decode(highlight, paths: paths, maxPixels: maxPixels)
                }.value
                loads[key] = nil
                finishedLoads += 1
                guard let picture else {
                    missing.insert(key)
                    return
                }
                let image = NSImage(cgImage: picture.image, size: NSSize(width: picture.image.width, height: picture.image.height))
                images.setObject(image, forKey: key as NSString, cost: picture.image.width * picture.image.height * 4)
            }
            loads[key] = task
        }
        await task.value
        return cached(for: highlight, paths: paths, maxPixels: maxPixels) ?? .missing
    }

    /// A decoded picture handed from the loading thread to the main one.
    /// A `CGImage` is immutable, so sharing it across threads is safe.
    struct Picture: @unchecked Sendable {
        let image: CGImage
    }

    /// Off the main thread: the file checks and ImageIO's downsampling.
    nonisolated private static func decode(_ highlight: HighlightRecord, paths: SessionPaths, maxPixels: Int) -> Picture? {
        guard let url = paths.regionImage(of: highlight),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        return Picture(image: image)
    }
}

/// Shows a region's picture once it is loaded: `content` gets the entry,
/// or nil while it loads.
struct RegionImageLoader<Content: View>: View {
    @EnvironmentObject private var state: AppState
    let highlight: HighlightRecord
    let maxPixels: Int
    @ViewBuilder let content: (RegionImageCache.Entry?) -> Content
    /// The result of this view's own load, with the key it was for: the
    /// composer's chip shows one region and then another.
    @State private var loaded: (key: String, entry: RegionImageCache.Entry)?

    var body: some View {
        let paths = state.sessionPaths
        let key = RegionImageCache.key(for: highlight, paths: paths, maxPixels: maxPixels)
        let entry = loaded.flatMap { $0.key == key ? $0.entry : nil }
            ?? RegionImageCache.cached(for: highlight, paths: paths, maxPixels: maxPixels)
        content(entry)
            .task(id: key) {
                guard RegionImageCache.cached(for: highlight, paths: paths, maxPixels: maxPixels) == nil else { return }
                let result = await RegionImageCache.load(for: highlight, paths: paths, maxPixels: maxPixels)
                loaded = (key, result)
            }
    }
}

/// A region's picture filling a small frame, as a card's marker and in the
/// composer's chip. Edged in the region's own color, like its box on the
/// page. A quiet empty frame while it loads; a dashed box when the picture
/// is missing.
struct RegionThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    let highlight: HighlightRecord
    let size: CGSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let maxPixels = Int((max(size.width, size.height) * max(displayScale, 1)).rounded(.up))
        RegionImageLoader(highlight: highlight, maxPixels: maxPixels) { entry in
            ZStack {
                switch entry {
                case .image(let image):
                    // The paper is white in both appearances; so is its picture.
                    Color.white
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                case .missing:
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: min(size.height * 0.6, 14)))
                        .foregroundStyle(.secondary)
                case nil:
                    Color.primary.opacity(0.05)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: RegionInk.outline(highlight.color)), lineWidth: 1))
    }
}

/// The larger picture on an expanded region card: the whole crop, fitted.
struct RegionPreview: View {
    @Environment(\.displayScale) private var displayScale
    let highlight: HighlightRecord
    /// Enough to tell the figure apart while the comment under it stays in
    /// view in a short list.
    static let maxHeight: CGFloat = 160

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        RegionImageLoader(highlight: highlight, maxPixels: Int((560 * max(displayScale, 1)).rounded(.up))) { entry in
            switch entry {
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Color.white)
                    .clipShape(shape)
                    // Edged in the region's color, like its thumbnail and its
                    // box on the page.
                    .overlay(shape.strokeBorder(Color(nsColor: RegionInk.outline(highlight.color)), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: Self.maxHeight, alignment: .leading)
                    .accessibilityLabel("Picture of the boxed area on page \(highlight.pageLabel)")
            case .missing:
                Label("The picture of this region is missing from the session folder", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case nil:
                shape
                    .fill(Color.primary.opacity(0.05))
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
            }
        }
    }
}

/// A region's outline color, the same shade as its box on the page.
@MainActor
enum RegionInk {
    static func outline(_ color: String) -> NSColor {
        PDFReaderView.Coordinator.regionStyle(color, selected: true, hovered: false).stroke
    }
}

// MARK: - Card

private struct CardPointerOverridesKey: EnvironmentKey {
    static let defaultValue: [UUID: PointerState] = [:]
}

extension EnvironmentValues {
    /// Draws the cards with these entry IDs as hovered or pressed regardless of
    /// the real pointer: the snapshot harness uses it, and a hover linked from
    /// the PDF can use it too.
    var cardPointerOverrides: [UUID: PointerState] {
        get { self[CardPointerOverridesKey.self] }
        set { self[CardPointerOverridesKey.self] = newValue }
    }
}

/// One card of the annotations list. Collapsed, the whole card is one click
/// target: its text is not selectable, because selectable text takes the
/// click. Expanded, the text can be selected and a click elsewhere on the card
/// collapses it.
struct AnnotationCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.cardPointerOverrides) private var pointerOverrides
    let entry: AnnotationEntry
    let expanded: Bool
    var query = ""
    @State private var hovering = false
    @GestureState private var pressing = false
    @State private var editingCommentID: UUID?
    @State private var editDraft = ""
    /// When a click on this card last expanded it, so the second click of a
    /// double-click does not collapse it again.
    @State private var expandedByClickAt: Date?

    private var pointer: PointerState {
        if let forced = pointerOverrides[entry.id] { return forced }
        if pressing { return .pressed }
        return hovering ? .hovered : .idle
    }

    private var showsControls: Bool { expanded || pointer != .idle }

    /// The card's region, when it is attached to one.
    private var region: HighlightRecord? {
        entry.highlight.flatMap { $0.isRegion ? $0 : nil }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // An expanded region shows its picture large across the card; the
            // thumbnail beside it would only repeat it.
            if region == nil || !expanded {
                AnchorMarkerView(marker: AnchorMarker(entry: entry))
                    .padding(.top, region != nil ? 0 : entry.comments.isEmpty ? 1 : 2)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let region, expanded {
                    RegionPreview(highlight: region)
                        .transition(.opacity)
                }
                if entry.comments.isEmpty, let highlight = entry.highlight {
                    if highlight.isRegion {
                        regionRow(highlight)
                    } else {
                        quoteRow(highlight)
                    }
                }
                ForEach(entry.comments) { comment in
                    commentBlock(comment)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinkedSurfaceBackground(
            flag: state.annotationHover.flag(for: entry.id),
            pointer: pointer,
            isSelected: expanded
        ))
        .contentShape(RoundedRectangle(cornerRadius: InteractionStyle.cornerRadius, style: .continuous))
        .animation(InteractionStyle.hover, value: pointer)
        .onHover { inside in
            hovering = inside
            reportHover(inside)
        }
        .onDisappear { reportHover(false) }
        // One gesture for the pressed look and the click. A tap gesture next
        // to a zero-distance drag never fires on macOS (the click test caught
        // it), so the drag acts as the click when the pointer barely moved.
        // Buttons inside the card take their own clicks first.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, pressing, _ in pressing = true }
                .onEnded { drag in
                    guard editingCommentID == nil,
                          abs(drag.translation.width) < 6,
                          abs(drag.translation.height) < 6 else { return }
                    clicked()
                },
            including: editingCommentID != nil ? .subviews : .all
        )
        .contextMenu { contextMenuItems }
        .help(expanded ? "" : region != nil
            ? "Click to show the picture and go to the region"
            : "Click to show the full text and go to the passage")
        .accessibilityAddTraits(expanded ? [.isSelected] : [.isButton])
        .padding(.horizontal, 8)
    }

    /// Lights the card's highlight on the page. Page-only comments have
    /// nothing drawn there.
    private func reportHover(_ inside: Bool) {
        guard entry.highlight != nil else { return }
        state.annotationHover.cardHoverChanged(entry.id, isHovering: inside)
    }

    private func clicked() {
        if expanded {
            if let expandedAt = expandedByClickAt,
               Date().timeIntervalSince(expandedAt) < NSEvent.doubleClickInterval { return }
            expandedByClickAt = nil
        } else {
            expandedByClickAt = Date()
        }
        state.selectEntry(entry)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let highlight = entry.highlight, highlight.isRegion {
            Button("Go to Region") { state.selectHighlight(highlight) }
            // A region has no quote; the text the PDF carries inside the box
            // (labels, tick values) is what there is to copy, when there is any.
            if let text = highlight.region?.textInRegion, !text.isEmpty {
                Button("Copy Text in Region") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Divider()
            Button("Remove Region", role: .destructive) { state.deleteHighlight(highlight.id) }
        } else if let highlight = entry.highlight {
            Button("Go to Highlight") { state.selectHighlight(highlight) }
            Button("Copy Highlighted Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(highlight.quote.normalizedForSearch, forType: .string)
            }
            Divider()
            Button("Remove Highlight", role: .destructive) { state.deleteHighlight(highlight.id) }
        }
        ForEach(entry.comments) { comment in
            Button("Delete Comment: \(comment.verbatim.prefix(30))…", role: .destructive) {
                state.deleteComment(comment.id)
            }
        }
    }

    /// A highlight with no comment shows its quote, since that is all it has.
    private func quoteRow(_ highlight: HighlightRecord) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(emphasized("“\(highlight.quote.normalizedForSearch)”"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .modifier(SelectableWhen(enabled: expanded))
                .frame(maxWidth: .infinity, alignment: .leading)
            controls {
                Button(role: .destructive) {
                    state.deleteHighlight(highlight.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove this highlight (⌘Z to undo)")
            }
        }
    }

    /// A region with no comment: its caption guess, which is what tells one
    /// figure from another at a glance, or a plain note that it has none.
    private func regionRow(_ highlight: HighlightRecord) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Group {
                if let caption = highlight.region?.captionGuess, !caption.isEmpty {
                    Text(emphasized(caption))
                        .help("The nearest caption on the page: a guess")
                } else {
                    Text("Region · no comment")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(expanded ? nil : 2)
            .modifier(SelectableWhen(enabled: expanded))
            .frame(maxWidth: .infinity, alignment: .leading)
            controls {
                Button(role: .destructive) {
                    state.deleteHighlight(highlight.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove this region (⌘Z to undo)")
            }
        }
    }

    @ViewBuilder
    private func commentBlock(_ comment: CommentRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                HStack(alignment: .top, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if comment.kind == .quiet {
                            Image(systemName: "pencil.line")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Margin note: recorded, not answered by the agent")
                        }
                        Text(emphasized(comment.verbatim))
                            .font(.body)
                            .lineLimit(expanded ? nil : 3)
                            .modifier(SelectableWhen(enabled: expanded))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    controls {
                        Button {
                            editDraft = comment.verbatim
                            editingCommentID = comment.id
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help("Edit this comment")
                        Button(role: .destructive) {
                            state.deleteComment(comment.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete this comment (⌘Z to undo)")
                    }
                }
            }

            if let reply = state.agentReplies[comment.id] {
                if expanded {
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
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity)
                } else {
                    Label("Agent replied", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Click the card to read the reply")
                }
            }
        }
    }

    /// Edit and delete controls: faded in on hover and when expanded. They
    /// keep their width while hidden so the text does not reflow on hover.
    private func controls<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .buttonStyle(IconButtonStyle())
        .opacity(showsControls ? 1 : 0)
        .allowsHitTesting(showsControls)
        .accessibilityHidden(!showsControls)
    }

    /// The card's text with search matches marked in the system find color.
    private func emphasized(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in AnnotationSearch.matchRanges(of: query, in: text) {
            guard let target = Range<AttributedString.Index>(range, in: attributed) else { continue }
            // Keyed by type: the key-path setters warn under strict concurrency.
            attributed[target][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color(nsColor: .findHighlightColor)
            // The find color is light in both appearances.
            attributed[target][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .black
        }
        return attributed
    }
}

/// The card's background, also drawn hovered while the pointer is on the
/// card's highlight on the PDF page. Its own view observing only this card's
/// flag, so a hover on the page redraws this background and nothing else of
/// the list. The edit and delete controls stay hidden then: the pointer is
/// not here to use them.
struct LinkedSurfaceBackground: View {
    @ObservedObject var flag: AnnotationHover.Flag
    var pointer: PointerState
    var isSelected: Bool

    var body: some View {
        InteractiveSurfaceBackground(
            pointer: pointer == .idle && flag.isHoveredOnPage ? .hovered : pointer,
            isSelected: isSelected
        )
        .animation(InteractionStyle.hover, value: flag.isHoveredOnPage)
    }
}

/// `textSelection` takes two different types for on and off, so it cannot be
/// switched with a ternary.
private struct SelectableWhen: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

/// Inline Markdown (emphasis, code, links) rendered through AttributedString;
/// falls back to the raw text when parsing fails.
struct MarkdownText: View {
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

// MARK: - Search field

/// A native search field: magnifier, clear button, and Esc clears it.
struct CommentSearchField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool
    /// Passed so the view updates when a new request arrives.
    var focusRequestID: UUID?
    var takeFocusRequest: () -> UUID?
    var isFocusRequestCurrent: @MainActor (UUID) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = WindowAwareSearchField()
        field.placeholderString = "Search comments"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        field.setAccessibilityLabel("Search comments")
        field.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.takeFocusIfRequested()
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = isEnabled
        context.coordinator.takeFocusIfRequested()
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CommentSearchField
        weak var field: NSSearchField?

        init(parent: CommentSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            publish(field.stringValue)
        }

        /// Also fires for the clear button and for Esc, which change the text
        /// without a text-change notification.
        @objc func searchFieldChanged(_ sender: NSSearchField) {
            publish(sender.stringValue)
        }

        private func publish(_ value: String) {
            if parent.text != value { parent.text = value }
        }

        func takeFocusIfRequested() {
            guard let field, parent.focusRequestID != nil else { return }
            KeyboardFocus.takeIfRequested(field, take: parent.takeFocusRequest, isCurrent: parent.isFocusRequestCurrent)
        }
    }
}

final class WindowAwareSearchField: NSSearchField {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

// MARK: - Esc on the list

/// Esc collapses the selected card unless the keyboard is in editable text.
/// A local key monitor, because after a card click the PDF view has focus and
/// its key handling cannot be changed from here; a hidden Esc button would
/// instead take Esc from the comment box and the search field too.
struct EscapeKeyMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.action = action
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    @MainActor
    static func shouldCollapse(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        eventWindow: NSWindow?,
        ownWindow: NSWindow?,
        firstResponder: NSResponder?,
        isEnabled: Bool
    ) -> Bool {
        isEnabled
            && keyCode == 53
            && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
            && ownWindow != nil
            && eventWindow === ownWindow
            && !isEditableText(firstResponder)
    }

    /// The comment box, the search field's editor and the inline comment
    /// editor are editable and keep Esc. The text view SwiftUI makes first
    /// responder when text in an expanded card is selected is read-only, and
    /// Esc should still collapse the card then.
    @MainActor
    static func isEditableText(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSText else { return false }
        return text.isEditable
    }

    final class MonitorView: NSView {
        var isEnabled = false
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self,
                              EscapeKeyMonitor.shouldCollapse(
                                  keyCode: event.keyCode,
                                  modifiers: event.modifierFlags,
                                  eventWindow: event.window,
                                  ownWindow: self.window,
                                  firstResponder: self.window?.firstResponder,
                                  isEnabled: self.isEnabled
                              ) else { return event }
                        self.action?()
                        return nil
                    }
                }
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Composer

struct CommentComposer: View {
    @EnvironmentObject private var state: AppState
    @State private var editorFocused = false

    private var saveTitle: String {
        if state.selectedHighlight != nil { return "Save linked" }
        if state.currentSelection != nil { return "Highlight + save" }
        return "Save to page"
    }

    private var placeholder: String {
        if let highlight = state.selectedHighlight {
            return highlight.isRegion ? "Comment on this region · ⌘↩ saves" : "Comment on this highlight · ⌘↩ saves"
        }
        if state.currentSelection != nil { return "Comment on the selection · ⌘↩ saves" }
        return "Comment on page \(state.currentPageLabel) · ⌘↩ saves"
    }

    private var saveHelp: String {
        if state.selectedHighlight?.isRegion == true { return "Save linked to the selected region (⌘↩)" }
        return state.hasCommentAnchor
            ? "Save linked to the highlighted text; a selection becomes a new highlight (⌘↩)"
            : "Save anchored to page \(state.currentPageLabel) (⌘↩)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ComposerAnchorChip()
                Spacer(minLength: 0)
                if let highlight = state.selectedHighlight {
                    Button("Detach", action: state.clearEntrySelection)
                        .controlSize(.small)
                        .help("Stop linking to the selected \(highlight.isRegion ? "region" : "highlight"); the next comment goes to the page")
                }
            }

            CommentTextEditor(
                text: $state.commentDraft,
                isFocused: $editorFocused,
                focusRequestID: state.commentFocusRequestID,
                takeFocusRequest: state.takeCommentFocusRequest,
                isFocusRequestCurrent: { [weak state] id in state?.isCommentFocusRequestCurrent(id) ?? false },
                onEscapeWhenEmpty: state.requestPDFFocus
            )
            .overlay(alignment: .topLeading) {
                if state.commentDraft.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, CommentTextEditor.textInset.width + 5)
                        .padding(.top, CommentTextEditor.textInset.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(editorFocused ? 0 : 0.15), lineWidth: 1)
            )
            .overlay(
                // The focus ring sits outside the box, like the system's.
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-2.5)
                    .opacity(editorFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(InteractionStyle.hover, value: editorFocused)

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
                .help(saveHelp)
            }
        }
        .padding(12)
    }
}

/// What the next comment attaches to, as a compact chip: the anchor's marker,
/// its page, and for a highlight the start of its quote.
struct ComposerAnchorChip: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let anchor = describe()
        HStack(spacing: 5) {
            anchor.icon
            Text(anchor.page)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            if let detail = anchor.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
        .help(anchor.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(anchor.help)
    }

    static let regionThumbnailSize = CGSize(width: 22, height: 16)

    private func describe() -> (icon: AnyView, page: String, detail: String?, help: String) {
        if let highlight = state.selectedHighlight, highlight.isRegion {
            let caption = highlight.region?.captionGuess.flatMap { $0.isEmpty ? nil : $0 }
            return (
                AnyView(RegionThumbnail(highlight: highlight, size: Self.regionThumbnailSize)),
                "Linked to region · p. \(highlight.pageLabel)",
                caption,
                "Linked to region · p. \(highlight.pageLabel)" + (caption.map { " · \($0)" } ?? "")
            )
        }
        if let highlight = state.selectedHighlight {
            let quote = "“\(highlight.quote.normalizedForSearch)”"
            return (
                AnyView(AnchorMarkerView(marker: .highlight(HighlightColor(rawValue: highlight.color) ?? .yellow))),
                "p. \(highlight.pageLabel)",
                quote,
                "Linked to highlight · p. \(highlight.pageLabel) · \(quote)"
            )
        }
        if let selection = state.currentSelection {
            let page = selection.primaryPageLabel ?? state.currentPageLabel
            return (
                AnyView(Image(systemName: "text.cursor").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: AnchorMarkerView.columnWidth)),
                "p. \(page)",
                "Selection · will be highlighted",
                "Selection · p. \(page) · will be highlighted"
            )
        }
        return (
            AnyView(AnchorMarkerView(marker: .page)),
            "Page \(state.currentPageLabel)",
            "Select text to link a comment to a passage",
            "Page \(state.currentPageLabel) · select text to link a comment to a passage"
        )
    }
}

/// The comment box: an NSTextView so Esc and focus can be handled exactly.
/// Esc with an empty draft hands the keyboard back to the PDF; with text it
/// does nothing (NSTextView would otherwise open the completion list).
struct CommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    /// Passed so the view updates when a new request arrives.
    var focusRequestID: UUID?
    var takeFocusRequest: () -> UUID?
    var isFocusRequestCurrent: @MainActor (UUID) -> Bool
    var onEscapeWhenEmpty: () -> Void

    static let textInset = NSSize(width: 4, height: 6)

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommentTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // As SwiftUI's TextEditor has them on this system (checked against it).
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
        textView.setAccessibilityLabel("Comment")
        textView.string = text
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        textView.onWindowChange = { [weak coordinator = context.coordinator] in
            coordinator?.takeFocusIfRequested()
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
        context.coordinator.takeFocusIfRequested()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentTextEditor
        weak var textView: CommentTextView?

        init(parent: CommentTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.onEscapeWhenEmpty()
            }
            return true
        }

        func focusChanged(_ focused: Bool) {
            // Responder changes can happen inside a view update; publish after.
            Task { @MainActor [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }

        func takeFocusIfRequested() {
            guard let textView, parent.focusRequestID != nil else { return }
            KeyboardFocus.takeIfRequested(textView, take: parent.takeFocusRequest, isCurrent: parent.isFocusRequestCurrent)
        }
    }
}

final class CommentTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onWindowChange: (() -> Void)?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
