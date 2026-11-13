import Foundation
import PaperCompanionCore
import SwiftUI

struct RecentPaper: Codable, Identifiable, Equatable {
    var id: String { sourcePath }
    var title: String
    var sourcePath: String
    var pageCount: Int
    var lastOpened: Date

    init(manifest: SessionManifest, lastOpened: Date) {
        title = manifest.title
        sourcePath = URL(fileURLWithPath: manifest.sourcePDFPath).standardizedFileURL.path
        pageCount = manifest.pageCount
        self.lastOpened = lastOpened
    }
}

/// A local index only: removing a row never changes a PDF or reading session.
@MainActor
final class RecentPapersStore: ObservableObject {
    @Published private(set) var papers: [RecentPaper] = []
    private let defaults: UserDefaults
    private let key = "PaperCompanion.recentPapers.v1"
    private let maximumCount = 50

    init(defaults: UserDefaults = .standard, sessionsRoot: URL? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([RecentPaper].self, from: data) {
            papers = Array(saved.sorted { $0.lastOpened > $1.lastOpened }.prefix(maximumCount))
        } else {
            // One-time migration; inspect only immediate session manifests,
            // never enumerate the user's PDFs or session contents recursively.
            let root = sessionsRoot ?? (try? SessionRepository().defaultSessionsRoot())
            if let root,
               let folders = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
               ) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let migrated = folders.filter { $0.pathExtension == "reading" }.compactMap { folder -> RecentPaper? in
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                          let manifest = try? decoder.decode(SessionManifest.self, from: data) else { return nil }
                    return RecentPaper(manifest: manifest, lastOpened: manifest.updatedAt)
                }.sorted { $0.lastOpened > $1.lastOpened }
                var seen = Set<String>()
                papers = Array(migrated.filter { seen.insert($0.id).inserted }.prefix(maximumCount))
            }
            save()
        }
    }

    func record(_ manifest: SessionManifest) {
        let paper = RecentPaper(manifest: manifest, lastOpened: Date())
        papers.removeAll { $0.id == paper.id }
        papers.insert(paper, at: 0)
        papers = Array(papers.prefix(maximumCount))
        save()
    }

    func remove(_ paper: RecentPaper) {
        papers.removeAll { $0.id == paper.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(papers) {
            defaults.set(data, forKey: key)
        }
    }
}

struct RecentPapersView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var library: RecentPapersStore
    var resumeReading: (() -> Void)?
    /// Loads a paper into the reader. A test passes its own, so no reading
    /// session is created.
    var openPaper: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your library").font(.largeTitle.weight(.semibold))
                    Text("Pick up a recent paper, with your highlights and notes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let resumeReading {
                    Button("Back to paper", action: resumeReading)
                }
                Button("Open PDF…", action: state.openPDF)
                    .buttonStyle(.borderedProminent)
            }
            if library.papers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Your recent papers will appear here").font(.headline)
                    Text("Open a PDF to start reading. Your original file stays unchanged.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(library.papers) { paper in
                            RecentPaperRow(
                                paper: paper,
                                isAvailable: FileManager.default.fileExists(atPath: paper.sourcePath),
                                open: { resume(paper) },
                                remove: { library.remove(paper) }
                            )
                        }
                    }
                    // Room for the lifted row's shadow inside the scroll view,
                    // which reaches past the column so the rows stay aligned
                    // with the heading.
                    .padding(8)
                }
                .padding(.horizontal, -8)
                .padding(.top, -8)
            }
        }
        .padding(32)
    }

    private func resume(_ paper: RecentPaper) {
        guard FileManager.default.fileExists(atPath: paper.sourcePath) else {
            state.errorMessage = "This PDF has moved or is unavailable. Use Open PDF to locate it. Your saved reading session has not been removed."
            return
        }
        let url = URL(fileURLWithPath: paper.sourcePath)
        if let openPaper {
            openPaper(url)
        } else {
            state.loadPDF(at: url)
        }
    }
}

/// One paper in the Library. The whole row is one button that resumes the
/// paper; it lifts under the pointer and presses down while the mouse is
/// down. The remove control sits on top of the row and fades in while the
/// pointer is on the row, or the keyboard is on the row or on the control:
/// SwiftUI drops a fully transparent control from the accessibility tree,
/// so it shows before Tab moves on to it. It is also in the context menu and
/// among the row's accessibility actions. A row whose PDF is missing is
/// dimmed and never lifts; a click on it explains how to find the file.
struct RecentPaperRow: View {
    let paper: RecentPaper
    let isAvailable: Bool
    var open: () -> Void
    var remove: () -> Void
    @Environment(\.pointerOverrides) private var overrides
    @State private var hovering = false
    @FocusState private var focusedPart: Part?

    private enum Part: Hashable { case row, remove }

    /// The row's key in `pointerOverrides`: its paper's path.
    private var overrideKey: String { paper.id }

    private var showsRemove: Bool {
        hovering || focusedPart != nil || overrides[overrideKey].map { $0 != .idle } == true
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) {
                RecentPaperRowContent(paper: paper, isAvailable: isAvailable)
            }
            .buttonStyle(LibraryRowButtonStyle(isAvailable: isAvailable, hovering: hovering, overrideKey: overrideKey))
            .focused($focusedPart, equals: .row)
            .help(isAvailable ? "Resume this paper" : "Locate this PDF using Open PDF")
            .accessibilityElement(children: .ignore)
            // Buttons have no value for VoiceOver; the details go in the label.
            .accessibilityLabel("\(paper.title), \(accessibilityDetails)")
            .accessibilityHint(isAvailable ? "Resumes this paper" : "The PDF is unavailable; use Open PDF to locate it")
            .accessibilityAction(named: "Remove from Recent Papers", remove)

            Button(action: remove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(IconButtonStyle())
            .focused($focusedPart, equals: .remove)
            .opacity(showsRemove ? 1 : 0)
            .animation(InteractionStyle.hover, value: showsRemove)
            .padding(.trailing, 12)
            .accessibilityLabel("Remove \(paper.title) from recent papers")
            .help("Remove from recents; keep the PDF and notes")
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if isAvailable {
                Button("Resume Paper", action: open)
                Divider()
            }
            Button("Remove from Recent Papers", action: remove)
        }
    }

    private var accessibilityDetails: String {
        let opened = RelativeDateTimeFormatter().localizedString(for: paper.lastOpened, relativeTo: Date())
        return "\(paper.pageCount) pages, opened \(opened)" + (isAvailable ? "" : ", file unavailable")
    }
}

/// What a Library row shows. Room is kept at the trailing end for the
/// remove control, which is not part of the row's button.
private struct RecentPaperRowContent: View {
    let paper: RecentPaper
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isAvailable ? "doc.text" : "doc.badge.ellipsis")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(paper.title).font(.headline).lineLimit(2)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                Text(paper.sourcePath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack {
                    Text("\(paper.pageCount) pages")
                    Text("·")
                    Text("Opened")
                    Text(paper.lastOpened, style: .relative)
                    Text("ago")
                    if !isAvailable { Text("· File unavailable").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(isAvailable ? 1 : 0)
            // The remove control's place.
            Color.clear.frame(width: 22, height: 20)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Library row: `RowSurfaceBackground` for rest, hover (lifted) and press.
/// Hover is tracked by the row around the button, so the pointer resting on
/// the remove control still counts as on the row.
struct LibraryRowButtonStyle: ButtonStyle {
    var isAvailable: Bool
    var hovering: Bool
    var overrideKey: String

    func makeBody(configuration: Configuration) -> some View {
        LibraryRowBody(configuration: configuration, isAvailable: isAvailable, hovering: hovering, overrideKey: overrideKey)
    }

    private struct LibraryRowBody: View {
        let configuration: ButtonStyleConfiguration
        let isAvailable: Bool
        let hovering: Bool
        let overrideKey: String
        @Environment(\.pointerOverrides) private var overrides

        private var pointer: PointerState {
            if let forced = overrides[overrideKey] { return forced }
            if configuration.isPressed { return .pressed }
            return hovering ? .hovered : .idle
        }

        var body: some View {
            configuration.label
                .background(RowSurfaceBackground(pointer: pointer, isAvailable: isAvailable))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(InteractionStyle.hover, value: pointer)
        }
    }
}
