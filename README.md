# Paper Companion

Paper Companion is a local-first macOS reader for academic PDFs. It combines native PDFKit reading and non-destructive highlights with transparent Markdown/JSON session files that an external Codex or Claude agent can understand while you read.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac supported by the installed Swift toolchain
- Xcode Command Line Tools to build from source

The packaged prototype is ad-hoc signed for local use. It is not Developer ID signed or notarized for general distribution.

## Core workflow

1. Open a PDF with **⌘O**.
2. Select text and press **⇧⌘H**, or enable **Auto-highlight selections** for drag-to-highlight reading. Remove a highlight from the Highlights tab; **⌘Z** restores the latest highlight change.
3. In Notes, choose **Highlight + save** for a quote-linked comment, or **Save page-only** for a comment anchored only to the current page. Saved comments remain visible in the app.
4. Press **⇧⌘M** for a **margin note** — anchored and recorded like any comment, but journalled so the agent files it without responding. This is for the reactions that are not worth a conversation: *nice explanation*, *this table is unreadable*, *lost the thread here*. They are read back at synthesis time, where a cluster of them on one section is itself a finding.
5. Keep document-level, unanchored Markdown notes in the Notes tab or detachable Notes window. The three Notes sections have draggable dividers.
6. Copy the agent prompt to discuss the current page, selection, highlights, and comments in your existing agent client.
7. Use the Highlights tab to return to passages. Clicking a highlight scrolls to the passage itself and tints it, rather than stopping at the top of its page.

The original PDF is never written or modified. Highlight rendering comes from sidecar records.

## Reading sessions

Sessions are created at:

```text
~/Documents/Paper Companion Sessions/<paper>-<fingerprint>.reading/
```

Important files:

- `notes.md`: your unanchored, document-level free-form notes.
- `comments.md`: generated readable projection of highlights, linked comments, and page-only comments.
- `state/comments.json`: structured source of truth for both comment types.
- `state/highlights.json`: app-owned highlight geometry and exact quotations.
- `bridge/current-context.json`: small, current page/selection snapshot for agents.
- `AGENTS.md`: instructions for an external filesystem-capable agent.
- `agent/transcript.md`: agent-owned verbatim comment transcript.
- `agent/shared-understanding.md`: agent-owned evolving interpretation.
- `agent/excursions/`: scoped research side trips, including the workshop synthesis.
- `cache/`: agent-owned derived copies of the paper — `pdf2md` output as `cache/paper.md`, rendered figure pages. Keeps conversions out of the folder holding the original PDF.

`AGENTS.md` is app-owned and rewritten from the template in `Sources/PaperCompanionCore/SessionRepository.swift` every time a session is opened, so protocol changes reach papers you have already started. Edit the template, not the copy inside a session.

It references two of the user's own references: `/Users/christoffer/.claude/research-standards/pdf-toolkit.md`, the authoritative path for deep PDF extraction, and `/Users/christoffer/docs/causal-inference/`, which the agent is told to route through before any comment that turns on an identifying assumption. `document-text.txt` is a convenient PDFKit extraction and can have incorrect reading order for columns, tables, or figures.

## Build and test

```bash
swift build
swift test
```

Package a local `.app`:

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh
```

## Known prototype limitations

- Text selection quality depends on the PDF text layer; OCR is not included.
- Highlights are sidecars and are not embedded back into the PDF.
- Agent integration is file-based. Paper Companion does not start, authenticate, or message an agent.
- Voice capture stays in your existing agent/client.
- The Agent tab reloads agent-owned files when you press Refresh; it does not yet watch them continuously.
- Direct external edits to `notes.md` while the app is open can be overwritten by a later in-app save.
- The app does not yet re-anchor sidecar highlights if the source PDF changes; the source fingerprint creates a separate session instead.

## Privacy

The app itself performs no network requests. For unpublished workshop papers, remember that asking an external agent to read the PDF or quotations may send that material to the agent provider. The generated agent instructions default literature excursions to decontextualized questions unless you explicitly permit sharing paper identity or text.
