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
                            paperRow(paper)
                        }
                    }
                }
            }
        }
        .padding(32)
    }

    private func paperRow(_ paper: RecentPaper) -> some View {
        let exists = FileManager.default.fileExists(atPath: paper.sourcePath)
        return HStack(spacing: 14) {
            Button {
                guard FileManager.default.fileExists(atPath: paper.sourcePath) else {
                    state.errorMessage = "This PDF has moved or is unavailable. Use Open PDF to locate it. Your saved reading session has not been removed."
                    return
                }
                state.loadPDF(at: URL(fileURLWithPath: paper.sourcePath))
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: exists ? "doc.text" : "doc.badge.ellipsis")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(paper.title).font(.headline).lineLimit(2)
                        Text(paper.sourcePath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        HStack {
                            Text("\(paper.pageCount) pages")
                            Text("·")
                            Text("Opened")
                            Text(paper.lastOpened, style: .relative)
                            Text("ago")
                            if !exists { Text("· File unavailable").foregroundStyle(.orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(exists ? "Resume this paper" : "Locate this PDF using Open PDF")
            Button {
                library.remove(paper)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(paper.title) from recent papers")
            .help("Remove from recents; keep the PDF and notes")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}
