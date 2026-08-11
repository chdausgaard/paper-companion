# Architecture review: native macOS PDF reading companion

## Recommended MVP shape

Use SwiftUI for application/window state and wrap one AppKit `PDFView` in `NSViewRepresentable`. Keep the PDF, session storage, and agent-facing files behind separate types:

- `PDFViewRepresentable` + coordinator: owns the displayed `PDFView`, observes selection/page notifications, and translates commands into PDFKit calls.
- `ReadingSessionStore` (`@MainActor`, observable): current page/selection, selected highlight, notes text, save status, and commands exposed to SwiftUI.
- `SessionRepository` (actor): Codable load/save, atomic file replacement, fingerprinting, and migration by schema version.
- `SourceAccessManager`: user-selected URLs and persistent security-scoped bookmarks.
- `TextExtractionService`: background extraction using its own `PDFDocument`, never the instance currently displayed by `PDFView`.

The main window should be a horizontal split: PDF in the large leading pane and an inspector with **Notes / Highlights / Context** tabs. Notes should also be detachable through a typed `WindowGroup(for: SessionID.self)` and `openWindow(value:)`. Both windows must resolve the same in-memory `ReadingSessionStore`; do not instantiate a second document/store in the notes window.

## Selection and non-destructive highlights

Observe `PDFViewSelectionChangedNotification` and copy `pdfView.currentSelection` immediately; the view's selection is ephemeral. Enable a toolbar command plus keyboard shortcut first. A custom PDFView context-menu item can follow.

For a selection:

1. Read `selection.string` and `selection.pages`.
2. Call `selection.selectionsByLine()` and create one rect per line/page with `line.bounds(for: page)`. A single union rectangle produces ugly blocks across margins and multi-column text.
3. Capture `numberOfTextRanges(on:)` / `range(at:on:)` for each involved page. These ranges are much better anchors for surrounding context than searching for a potentially repeated quote.
4. Render each line as `PDFAnnotation(bounds:forType:.highlight,withProperties:nil)`, set its color/opacity, and add it to the page.

Adding an annotation mutates the in-memory `PDFDocument`, so **never save that document over the source PDF**. Persist the highlight as sidecar JSON and recreate transient annotations whenever the PDF opens. Keep an in-memory mapping from the sidecar highlight UUID to the annotation objects so deleting a highlight only removes those objects. `PDFPageOverlayViewProvider` is an alternative on macOS 13+, but PDF annotations already track PDFView zoom/rotation correctly and are the lower-risk MVP.

## Coordinate and identity persistence

Store page-space coordinates, not view coordinates. A highlight record should include:

```json
{
  "id": "UUID",
  "pageIndex": 6,
  "pageLabel": "7",
  "quote": "exact selected text",
  "textRanges": [{"location": 1440, "length": 93}],
  "lineRects": [{"x": 72, "y": 418, "width": 386, "height": 12}],
  "cropBox": {"x": 0, "y": 0, "width": 612, "height": 792},
  "rotation": 0,
  "createdAt": "ISO-8601",
  "color": "yellow"
}
```

`PDFSelection.bounds(for:)` is relative to page content, not a `PDFDisplayBox`, so retain the raw PDF-space rects. Record crop box and rotation as diagnostics, and optionally normalized rects as a fallback. Bind the whole session to a streaming SHA-256 digest of the original PDF bytes. If the digest differs on reopen, do not silently paint old coordinates: attempt re-anchoring from page index + text range + exact quote, then quote/context search, and mark ambiguous cases unresolved.

## Agent-readable context and text extraction

For immediate context, use the selection's page text and recorded `NSRange` values to emit the selected quote plus a bounded prefix/suffix. For whole-document extraction, iterate `PDFPage.string` using a **separate** `PDFDocument` on a serial background actor. PDFKit extraction is best-effort: reading order can be wrong for columns/tables, and image-only PDFs return no usable text. Surface that limitation; do not imply OCR.

The user's existing PDF toolkit should remain the authoritative deep-reading path. It already prescribes `pdfheadings`/`pdf2md`, deterministic files in `~/Documents/pdf-library/papers/`, page-level extraction audits when needed, and separate notes in the vault root. Do not duplicate or modify converted paper Markdown. Put a source path and digest in the session manifest so an agent can run that workflow, and let the session point to the resulting library Markdown when present. The app itself should not shell out to `pdf2md` in the MVP because a packaged app cannot assume the CLI or shell environment exists.

## Session folder and file ownership

Use transparent files in a user-selected session root, with strict single-writer ownership:

```text
Paper Name.reading/
  session.json                 # app-owned metadata, schemaVersion, source path/digest
  highlights.json              # app-owned structured highlights
  notes.md                     # edited by the app/user
  current-context.json         # app-owned, atomically replaced on selection change
  agent/
    shared-understanding.md    # agent-owned
    transcript.md              # agent-owned
    questions.json             # agent-owned
    excursions/
```

Do not let both the app and an agent rewrite the same file. The app may display agent-owned files read-only and watch their directory for changes. Save app-owned JSON by encoding to a temporary file in the same directory and replacing the destination atomically; serialize saves through `SessionRepository`. Debounce notes autosave and use `NSFileCoordinator` when an external editor may touch `notes.md`. Maintain `.bak` only for the most recent valid prior JSON, and validate schema before replacing it.

`current-context.json` should stay small and contain session ID, source digest/path, page index/label, exact selection, nearby context, linked highlight ID, and timestamp. It is the clean bridge for voice/Codex interaction; an agent need not parse PDF annotations.

## File access and safe local storage

For a sandbox-capable build:

- Open PDFs with `NSOpenPanel`/SwiftUI `fileImporter` restricted to `UTType.pdf`.
- Ask once for a session-root directory and retain its security-scoped bookmark with read/write access. Retain PDF bookmarks read-only unless the PDF is inside that root.
- Create bookmark data with `.withSecurityScope`; resolve with the same option, handle the stale flag, and call `startAccessingSecurityScopedResource()` only for the duration of access (balanced with `stopAccessing...`).
- Keep bookmark blobs and the recents index in `Application Support`; keep agent-readable session artifacts in the chosen ordinary folder. A bookmark blob is not an agent-friendly substitute for a source path.
- Never overwrite, relocate, or annotate the original PDF. Any “export annotated PDF” feature must use a save panel and a new destination.
- Default to local-only processing. Never send an unpublished PDF, extracted text, or highlighted quotations to a network service implicitly.

If existing TXT/Markdown files must be opened rather than imported, give them their own read/write security-scoped bookmark and coordinate writes. For the first version, a session-managed `notes.md` plus Import/Export is safer and easier to recover than treating arbitrary text files as live documents.

## Highest-value verification

Before calling the MVP reliable, test these cases:

1. A two-column academic PDF: multi-line highlight follows the correct lines at several zoom levels.
2. A rotated/cropped page: persisted highlight lands correctly after relaunch.
3. A selection spanning two pages: quote, per-page ranges, rects, and deletion all remain grouped under one highlight ID.
4. Original PDF checksum is unchanged after highlight add/delete and app quit.
5. Stale/moved PDF bookmark produces a relink flow rather than data loss.
6. Two windows edit/view the same session without duplicate stores or lost notes.
7. Image-only PDF clearly reports unavailable text while visual reading/highlighting behavior is handled explicitly (likely no text selection without OCR).
8. An agent updates `agent/shared-understanding.md` while the app is open; the app reloads it without clobbering agent work.

The key MVP boundary is: excellent PDF viewing, sidecar highlights, notes, and a transparent context bridge. Embedded chat, OCR, PDF annotation export, and autonomous literature searches should remain later layers.
