# Recent papers library handoff

Implemented in `Sources/PaperCompanion/RecentPapers.swift` and `ContentView.swift`.

- Library is the no-document landing view; toolbar Library opens it during reading, and Back to paper returns without unloading the active document.
- Opening a row uses existing `AppState.loadPDF`, restoring normal saved session state. A new PDFDocument object closes the library even when reopening the same path.
- Up to 50 recent paths, title, page count, and opening timestamp persist in UserDefaults. Successful opens deduplicate and move the paper first.
- First use migrates immediate `.reading/session.json` files under the existing session root, ordered by updatedAt. No recursive PDF/content scan. Empty persisted index prevents removed entries migrating back.
- Missing PDFs remain visible and give an actionable Open PDF message. Removing an entry only updates the index; PDFs and sessions remain intact.
- ContentView also integrates parent's AppUpdates environment object, startup task, notice sheet, and Request Feature button.

AppState integration (parent owns this file): `let recentPapers = RecentPapersStore()`; call `recentPapers.record(loaded.manifest)` after successful `writePageContext()` in loadPDF.

Validation: `CLANG_MODULE_CACHE_PATH=/tmp/paper-companion-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/paper-companion-module-cache swift build --disable-sandbox` passed. Default swift build was blocked writing the user module cache, resolved with writable temporary cache. Native UI has not been visually exercised by this sub-agent.

## Focused tests

Added `Tests/PaperCompanionAppTests/RecentPapersTests.swift` with isolated UserDefaults suites and temporary session roots. Three tests passed with `swift test --disable-sandbox --filter RecentPapersTests` (temporary module-cache environment variables as above):

- Reopening moves a paper first, refreshes title/page count, persists across store initialization, and avoids duplicate paths.
- Removing persists across initialization while keeping the original PDF bytes and session manifest intact, including an empty recents list after migration.
- Migration sorts by session update date, deduplicates sources, ignores nested and malformed sessions, and runs only once even when more sessions appear later.
