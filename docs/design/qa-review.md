# PaperCompanion prototype: QA and packaging handoff

## Scope and release bar

This plan covers a native macOS SwiftUI/PDFKit prototype built with Swift Package Manager and shipped as a local `.app`. It treats the durable reading-session files as the product boundary: PDF text/selection context, highlight records, comments, and Markdown output must remain readable outside the app and must survive reopening the app.

The prototype is ready to hand to the user only when all of the following are true:

- `swift build` and `swift test` pass from a clean checkout/build directory.
- A release executable is embedded in a structurally valid `.app` bundle.
- The bundle launches on the target Mac without an immediate crash or Gatekeeper/code-signature error.
- The persistence, record-linking, current-context, and Markdown-export behaviors below have automated coverage.
- A human has completed the PDFKit/SwiftUI interaction pass, because these behaviors cannot be validated reliably by headless SwiftPM tests alone.
- The user-facing deliverable is copied to `outputs/`, then independently checked there (not merely in `.build/`).

## Testable implementation seams

Keep persistence and export logic in a library target imported by both the executable and tests. A useful SwiftPM layout is:

```text
Package.swift
Sources/
  PaperCompanionCore/       # Codable models, session store, context writer, Markdown exporter
  PaperCompanion/           # SwiftUI app, PDFKit bridge, AppKit window commands
Tests/
  PaperCompanionCoreTests/
  Fixtures/
scripts/
  package-app.sh
```

The executable target should contain as little data logic as possible. `PDFView`, `NSOpenPanel`, pasteboard/selection events, menu commands, and window presentation belong there; encoding, atomic file writes, path construction, comment/highlight linking, and Markdown generation belong in `PaperCompanionCore`. This separation is what makes the core workflow testable with `swift test` without launching a GUI.

Every storage-oriented test should create a unique directory under `FileManager.default.temporaryDirectory`, inject it into the session store, and remove only that exact directory in `tearDown`. Tests must never use the real Application Support location or the user's documents.

Recommended fixtures:

- A tiny redistributable two-page PDF whose page text is known exactly, including one line break and one non-ASCII character.
- A corrupt/non-PDF file with a `.pdf` extension.
- A session fixture containing two highlights on different pages, two linked comments, and one standalone comment.
- A legacy or partially missing session fixture if the implementation promises recovery/migration; otherwise explicitly reject unsupported schema versions with a useful error.

## Automated test matrix

### Session persistence

1. **Round trip:** Create a session with a stable session ID, PDF reference/path metadata, optional plain-text notes, two highlights, linked comments, and timestamps. Save, instantiate a fresh store, reload, and compare semantic equality. Do not compare JSON bytes or dictionary key order.
2. **Stable identity:** Repeated saves preserve session, highlight, and comment IDs. Editing comment text must not create a replacement record unless the UI explicitly invokes duplicate/new.
3. **Atomic replacement:** A successful save leaves one complete readable current file and no visible half-written result. If the store uses a temporary file plus rename, assert the temporary sibling is absent after success.
4. **Missing session:** Loading a nonexistent session returns a typed `notFound` result or creates a new session according to the documented API; it must not crash or silently load unrelated data.
5. **Malformed data:** Truncated JSON/JSONL returns a useful error and does not overwrite the malformed original during load.
6. **Unknown fields:** Adding an unknown field to persisted JSON should still load, allowing forward-compatible sidecar metadata.
7. **Unicode and multiline text:** Round-trip Danish/non-ASCII characters, curly quotes, Markdown punctuation, and multiline comments exactly.
8. **Repeated save:** Save the same state twice and verify that records are not duplicated. If an `updatedAt` value changes, compare all other semantic fields rather than requiring byte-identical files.
9. **Path behavior:** Spaces and non-ASCII characters in the PDF/session path work. Relative paths, bookmarks, or copied-document semantics should be tested according to the chosen implementation, without assuming the original PDF can always be written.
10. **Original-file safety:** Saving a session does not alter the original PDF bytes unless annotation embedding is an explicit feature. Capture a SHA-256 hash before and after the test.

### Highlight and comment records

1. **Required provenance:** A highlight record preserves stable ID, source/session ID, one-based user-facing page number (or clearly documented zero-based internal page index), selected text, surrounding text if supported, bounds/quads if supported, and creation time.
2. **Selection normalization:** Define and test the policy for PDF line breaks and whitespace. Suggested policy: preserve the verbatim selection in `selectedText`, and store any normalized searchable representation separately. Never irreversibly normalize the only copy.
3. **Duplicate text:** Two identical quotations on different pages remain distinct because identity is record-based, not quote-text-based.
4. **Comment linking:** A comment linked to highlight H1 reloads linked to H1; editing/deleting H2 must not change it. Standalone paper-level comments remain valid without a highlight ID.
5. **Orphan policy:** Deleting a highlight must have deterministic behavior: either retain its comments as paper-level/orphaned comments or delete them only after explicit confirmation. Test the chosen policy.
6. **Bounds encoding:** If `CGRect`/PDF quadrilaterals are persisted, round-trip their scalar values with a tolerance and retain the page index. Avoid direct archival of framework objects such as `PDFAnnotation` or `PDFSelection`.
7. **Ordering:** The displayed/exported order is deterministic—recommended: PDF page, then vertical position if available, then creation time and stable ID as tie-breakers.

### Current context bridge

Treat the agent-facing context file as a small, versioned snapshot rather than an append-only log. Test:

1. Selecting a highlight writes its stable ID, exact selected text, page, source PDF/session identity, surrounding context when available, and an ISO-8601 update time.
2. Selecting another highlight atomically replaces the snapshot; no fields from the previous selection leak into the new one.
3. Clearing selection produces either an explicit `selection: null` snapshot or removes the file, according to one documented contract. Test that stale context is never left looking current.
4. A quote containing newlines, quotes, backslashes, Unicode, or Markdown delimiters remains valid UTF-8 JSON and reloads exactly.
5. Context generation from an empty or image-only PDF page succeeds with empty/unavailable surrounding text and a status field; it must not invent OCR text.
6. Rapid updates are last-write-wins and produce valid JSON. If the writer is an actor or uses a serial queue, stress it with many concurrent update requests and verify the final requested record plus decoder validity.
7. The file exposes no more source text than intended. The default should be exact selection plus a bounded surrounding excerpt, not the entire unpublished paper.
8. If an agent instruction/readme points to this file, verify its documented filename and schema match the actual output.

### Markdown/TXT export

1. **Golden export:** Export a fixed session and compare with a checked-in `.md` golden fixture after normalizing only platform line endings and deliberately dynamic timestamps.
2. **Structure:** Assert one title, source metadata, and predictable sections for highlights/comments. Linked comments appear adjacent to their highlight; standalone comments appear in a distinct section.
3. **Citation/location:** Each highlight carries a human-readable page reference and stable record ID so an agent can refer back unambiguously.
4. **Escaping:** Quotes containing `>`, backticks, headings, HTML-like text, and multiline content cannot break the surrounding document structure. Fenced blocks, if used, must select a fence longer than any run found in the content.
5. **No fabricated fields:** Missing authors/title/page text are omitted or labeled unavailable; the exporter never inserts guessed metadata.
6. **Determinism:** Two exports of unchanged data have identical body/order. If a generated timestamp is included, inject a clock in tests or exclude that single header field from comparison.
7. **Overwrite safety:** Export to an existing destination uses the explicit replace/cancel policy and does not truncate the file if generation fails.
8. **Plain-text compatibility:** If `.txt` export is supported, test it separately; do not merely save Markdown under a `.txt` name without documenting that choice.

### Suggested XCTest organization

Use small behavior-focused suites rather than a single integration test:

```text
SessionStoreTests
HighlightCommentModelTests
CurrentContextWriterTests
MarkdownExporterTests
SessionWorkflowIntegrationTests
```

The integration suite should exercise: create session → add highlight → attach dictated/text comment → write current context → save → reload in a fresh store → export Markdown. This is the minimum automated proof of the central workflow.

## Build and static checks

Run from the package root and save the output if any step fails:

```bash
swift package describe
swift package resolve
swift build
swift test --parallel
swift build -c release
```

Also perform a clean build at least once before handoff:

```bash
swift package clean
swift build -c release
swift test
```

Review compiler warnings manually. The handoff bar is zero warnings in project-owned source. Pay particular attention to Swift 6 concurrency warnings, main-actor isolation for UI state, unchecked `Sendable`, and nonisolated file-store access.

If supported by the installed toolchain, use the compiler's strict-concurrency settings in the package rather than relying only on an ad-hoc command. Avoid making formatter/linter installation a prerequisite for this prototype; a formatter or SwiftLint check is welcome only if already configured and reproducible.

## `.app` packaging contract

The packaging script should be deterministic and fail on the first error. It should:

1. Run a release build for the host architecture (or both `arm64` and `x86_64` only if universal distribution is actually required).
2. Create `PaperCompanion.app/Contents/{MacOS,Resources}` in a fresh staging directory.
3. Copy the executable to `Contents/MacOS/PaperCompanion` and mark it executable.
4. Copy declared SwiftPM resources into `Contents/Resources`; do not assume SwiftPM resource bundles are embedded automatically by a hand-built app bundle.
5. Write a valid `Contents/Info.plist` including at least `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`, `CFBundleDisplayName`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, and the true minimum macOS version.
6. Add PDF document-type declarations only if Finder open-with support is implemented and tested. Do not claim the app edits PDFs in place if it uses sidecars.
7. Ad-hoc sign the final local bundle (`codesign --force --deep --sign -`) after all files are in place. Developer ID signing/notarization is a separate release path requiring the user's Apple credentials.
8. Copy the final bundle to `outputs/` only after validation succeeds.

Bundle validation commands:

```bash
test -x "outputs/PaperCompanion.app/Contents/MacOS/PaperCompanion"
plutil -lint "outputs/PaperCompanion.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "outputs/PaperCompanion.app"
file "outputs/PaperCompanion.app/Contents/MacOS/PaperCompanion"
```

Inspect `otool -L` output to catch unexpected non-system dynamic-library paths. If the product has SwiftPM resource bundles, inspect the final tree and launch the packaged copy—not the executable directly from `.build/release`—to prove resources resolve correctly.

Do not report `spctl --assess` failure as an app defect for an ad-hoc-signed local prototype; Gatekeeper distribution outside the local Mac requires Developer ID signing and notarization. Do report this limitation plainly.

## Manual visual and interaction pass

Use the packaged app in `outputs/` with a disposable copy of a real academic paper and a temporary session directory.

### Launch and document handling

- Launch from Finder and from `open outputs/PaperCompanion.app`; verify only one initial window and no immediate crash.
- Open a valid PDF via File → Open (and drag/drop or Finder association only if implemented).
- Cancel the open panel; the existing session must remain unchanged.
- Try the corrupt PDF fixture and a password-protected or image-only PDF if available; show an actionable error without losing current work.
- Close and reopen the app/session and confirm page position, highlights, comments, and note text are restored to the documented extent.

### PDFKit reading behavior

- Check one-page and long PDFs at fit-width, fit-page, and zoomed levels.
- Search for a term with multiple hits; move between hits and clear search.
- Select across wrapped lines and, if common in the user's papers, across a two-column layout. Confirm the captured quote/page match the visible selection.
- Create two highlights with the same quote on different pages and verify both remain independently selectable.
- Resize the window narrow/wide, enter full screen, and switch light/dark appearance. The PDF remains readable and controls do not overlap.
- Scroll away and back; annotations/overlays stay aligned with the underlying PDF after zoom and resize.

### Notes/comments workflow

- Add a comment to the active highlight, then a standalone paper-level comment.
- Enter multiline text, Danish characters, smart punctuation, Markdown delimiters, and paste a long paragraph.
- Edit a comment and verify autosave/explicit-save feedback is unambiguous.
- Delete a highlight with a linked comment and confirm the advertised orphan/delete behavior.
- Switch rapidly between highlights; the notes panel and current-context snapshot must correspond to the final active highlight.
- If notes open in a separate window, close/reopen it and verify edits synchronize without duplication or lost text.

### Agent bridge and export

- With a highlight selected, inspect the generated current-context file in a text editor; verify quote, page, IDs, and surrounding excerpt against the PDF.
- Clear selection and confirm context is not stale.
- Export Markdown, open it in a plain editor, and confirm it remains understandable without the app.
- Ask an agent to read only the documented session artifacts and identify a particular highlighted passage/comment. This validates discoverability and schema documentation, not the model's substantive interpretation.
- Confirm that no web call or automatic upload occurs merely from opening or highlighting an unpublished paper.

### macOS quality basics

- Verify standard menu items and shortcuts work (`⌘O`, `⌘W`, `⌘Q`, copy, find if implemented).
- Verify keyboard focus is visible and the main workflow is possible without precise pointer-only targets.
- Check VoiceOver labels for toolbar buttons and icon-only controls.
- Verify empty, loading, save-failure, and unavailable-selection states have user-facing explanations.
- Leave the app idle, switch away/back, sleep/wake if practical, and confirm unsaved state is not discarded.

Record the macOS version, hardware architecture, app version/build, PDF fixture, and pass/fail notes. Screenshots are useful for layout defects but are not substitutes for the interaction pass.

## Limits of headless and automated testing

- SwiftPM unit tests can validate models, storage, context JSON, and export output; they cannot establish that PDF selections, highlight overlays, scrolling, zooming, or window focus feel correct.
- `PDFKit` text extraction and selection geometry can vary with PDF producer, embedded fonts, OCR/text layers, ligatures, columns, and macOS release. A synthetic fixture is necessary but insufficient; test at least one real born-digital paper.
- XCTest UI automation normally requires an Xcode project/scheme and a UI-test runner, which a minimal SwiftPM executable package does not provide. Adding a generated Xcode project solely for superficial UI assertions is not necessary for the prototype.
- Opening a GUI from a shell may succeed while the process crashes after launch. Confirm the app remains running briefly, inspect Console/unified logs if it does not, and interact with the actual window.
- Screenshot comparison is fragile across macOS versions, display scale, font rendering, and PDFKit. Prefer semantic core tests plus a short visual checklist over pixel-perfect snapshots.
- Ad-hoc code signing proves bundle integrity on the development Mac, not distributability. A clean-machine test is the real validation for any future external release.

## Deliverable verification and handoff evidence

Before reporting completion, verify from the final output location:

1. `outputs/PaperCompanion.app` exists and has a non-empty executable.
2. `Info.plist` passes `plutil -lint` and its executable name matches the binary exactly, including case.
3. `codesign --verify --deep --strict` passes after the final copy.
4. The packaged app launches and can open the test PDF.
5. `swift test` passes after the final source changes.
6. The delivered README states minimum macOS version, local/ad-hoc signing status, where session files live, whether original PDFs are modified, how to open a PDF, how to export notes, and what agents should read.
7. Any sample/session artifact shipped to the user contains no confidential paper text or personal paths.
8. File sizes are plausible (`du -sh` on the bundle); reject a zero-byte executable or missing SwiftPM resource bundle.

Preserve a concise handoff record with the exact commands run, exit results, macOS/Swift versions, manual-check status, and known limitations. Do not label the build fully verified if only core tests passed and the packaged GUI was never opened.

## Recommended initial known limitations

For a first prototype, the README should explicitly state any of the following that remain true:

- Highlights are sidecar records and may not be embedded into/exportable as standard PDF annotations.
- Selection quality depends on the PDF's text layer; OCR is not provided.
- Agent integration is file-based; the app does not start, authenticate, or message an agent.
- Voice capture occurs in the user's existing agent/client, not in PaperCompanion.
- The bundle is ad-hoc signed for local use and is not notarized for general distribution.
- No guarantee yet exists for external edits to session files while the app is running; if file watching is absent, reopen/reload explicitly.

These limitations are acceptable if the core reading loop is reliable and the artifacts remain transparent, local, and recoverable.
