# Update and feature-request UI handoff

Implemented in `Sources/PaperCompanion/AppUpdates.swift` with no dependencies.

Integration:
- Own one `AppUpdates` state object in the app and inject it into `ContentView`.
- Run `await updates.start()` in the content view's `.task`.
- Present `.sheet(item: $updates.notice, onDismiss: updates.noticeDismissed)` using `UpdateNoticeView`.
- Add app-menu actions for Check for Updates and What's New, and visible feature-request controls that call `requestFeature()`.

Behavior:
- One automatic GitHub latest-release check per process launch. Background errors and no-release states remain quiet.
- Explicit checks report failures, no published release, up-to-date status, or a newer release.
- GitHub release page opens for user-managed download and installation; no automatic installer is included.
- First launch and version/build changes show What's New. The installed identity is tracked in UserDefaults. Showing on first launch also covers upgrades from older versions without tracking.
- If an update arrives while What's New is visible, queue its notice until dismissal.
- Feature Request opens a prefilled GitHub issue draft; users review and submit in the browser (GitHub login may be needed).
- Repository verified from README: chdausgaard/paper-companion.

Release maintenance: bundled notes currently describe version 0.4.0; update the version condition and notes when changing VERSION. Other versions link to GitHub release notes.

Validation: `CLANG_MODULE_CACHE_PATH=/tmp/paper-companion-clang-cache swift test --disable-sandbox --filter AppUpdatesTests` passed (1 test, 6 numeric comparison assertions), compiling the full app. Ordinary swift build initially hit sandbox restrictions on the default clang cache. Live GitHub requests and browser issue submission were not exercised.
