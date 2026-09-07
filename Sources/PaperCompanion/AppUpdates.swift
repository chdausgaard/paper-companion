import AppKit
import SwiftUI

/// Checks published GitHub releases; installation stays with the user in their browser.
@MainActor
final class AppUpdates: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var releaseURL: URL? = nil
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
    }

    static let releasesURL = URL(string: "https://github.com/chdausgaard/paper-companion/releases")!
    @Published var notice: Notice?
    @Published private(set) var isChecking = false
    private var started = false
    private let defaults: UserDefaults
    private let version: String
    private let build: String
    private var pendingUpdate: Notice?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    }

    func start() async {
        guard !started else { return }
        started = true
        let identity = "\(version) (\(build))"
        let previous = defaults.string(forKey: "lastLaunchedAppVersion")
        defaults.set(identity, forKey: "lastLaunchedAppVersion")
        if previous != identity {
            showWhatsNew()
        }
        await check(manual: false)
    }

    func showWhatsNew() {
        notice = Notice(
            title: "What’s New in Paper Companion \(version)",
            detail: version == "0.4.0" ? """
            • Click a highlight and press Backspace to delete it and its linked comments. Undo restores them.
            • Change highlight colors or remove highlights from the right-click menu.
            • Reopen papers from the recent-paper library on the welcome screen.
            • Check for updates and send feature requests directly from the app.
            """ : "This version of Paper Companion has been installed. Open the release notes for the full list of changes.",
            releaseURL: Self.releasesURL
        )
    }

    func check(manual: Bool = true) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/chdausgaard/paper-companion/releases/latest")!)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("PaperCompanion/\(version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await Self.fetch(request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 404 {
                if manual { notice = Notice(title: "No Published Updates", detail: "No public release is available yet. You’re running Paper Companion \(version).", releaseURL: Self.releasesURL) }
                return
            }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease else { return }
            if Self.isNewer(release.tag_name, than: version) {
                let update = Notice(title: "Paper Companion \(release.tag_name) Is Available", detail: "You’re running version \(version). Open the release page to download and install the update.\n\n\(release.body ?? "See the release page for changes.")", releaseURL: Self.releasesURL)
                if notice == nil || manual { notice = update } else { pendingUpdate = update }
            } else if manual {
                notice = Notice(title: "You’re Up to Date", detail: "Paper Companion \(version) is the latest available version.")
            }
        } catch {
            if manual { notice = Notice(title: "Couldn’t Check for Updates", detail: "Check your internet connection and try again. You can also check the releases page in your browser.", releaseURL: Self.releasesURL) }
        }
    }

    func noticeDismissed() {
        if let pendingUpdate {
            self.pendingUpdate = nil
            notice = pendingUpdate
        }
    }

    func requestFeature() {
        var components = URLComponents(string: "https://github.com/chdausgaard/paper-companion/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Feature request: "),
            URLQueryItem(name: "body", value: "## What would you like to do?\n\n\n## How would this help your reading workflow?\n\n\n---\nPaper Companion \(version) (\(build))")
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    nonisolated private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.hasPrefix("v") ? String(value.dropFirst()) : value
        }
        let candidate = normalized(candidate)
        let current = normalized(current)
        // Release tags must use numeric dotted versions. Ignore unrelated tags.
        guard candidate.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else { return false }
        let left = candidate.split(separator: ".").compactMap { Int($0) }
        let right = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

struct UpdateNoticeView: View {
    let notice: AppUpdates.Notice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(notice.title).font(.title2.weight(.semibold))
            ScrollView {
                Text(notice.detail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                if let url = notice.releaseURL {
                    Link("Open Release Page", destination: url)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
