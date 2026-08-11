# Paper Companion 0.2.1

Paper Companion is a local-first macOS reader for academic PDFs. It keeps the
original PDF unchanged while storing highlights, page-linked comments, free-form
notes, and agent context in a separate reading-session folder.

## Start

1. Double-click `PaperCompanion.app`.
2. Choose **Open PDF** and select a paper.
3. Select text and press **⇧⌘H**, or turn on **Auto-highlight selections** for
   drag-to-highlight reading. Remove highlights in the Highlights tab and use
   **⌘Z** to undo the latest highlight change.
4. In **Notes**, choose **Highlight selection + save** for a quote-linked comment,
   or **Save page-only** for a comment anchored only to the current page.
5. Use **Document notes (not anchored)** for paper-wide Markdown notes, or open
   the detachable Notes Window from the toolbar.

The app is locally built and ad-hoc signed, not notarized for public distribution.
If macOS blocks the first launch, Control-click the app, choose **Open**, and
confirm once.

## Reading workflow

- **Notes** visibly distinguishes quote-linked comments, page-only comments, and
  unanchored document notes. Saved comments remain listed after capture and have
  individual trash buttons; **⌘Z** restores a deleted comment.
- **Highlights** lists saved text anchors and exports a readable `comments.md`.
- **Agent** shows the exact bounded context currently shared with an external
  agent: paper identity, page, selected/highlighted text, nearby page text, and
  your verbatim comment history.
- **Copy agent prompt** copies a short prompt that tells Codex or Claude where the
  session files and protocol live.
- **Reveal folder** opens the session folder so an agent can work there directly.

This design deliberately keeps your words separate from an agent's interpretation.
The app owns `notes.md`, `comments.md`, `current-context.*`, and the files under
`state/`; an agent writes its evolving synthesis to `agent/shared-understanding.md`
and its work log to `agent/transcript.md`.

## Files and privacy

By default, sessions are stored in:

`~/Documents/Paper Companion Sessions/`

The original PDF is never annotated or overwritten. Highlights are sidecar records
with page-space rectangles, selected text, text ranges, and a PDF fingerprint. The
agent bridge is file-based and local; Paper Companion does not upload papers or
require an API key.

Each session includes an `AGENTS.md` that directs research agents to the supplied
PDF toolkit at:

`/Users/christoffer/.claude/research-standards/pdf-toolkit.md`

For scanned or image-only PDFs, run OCR or the toolkit's deeper extraction workflow
first; native selection and highlighting require a usable PDF text layer.

## Included verification

- Swift package debug and release builds
- Twelve automated workflow, undo/redo, comment anchoring/deletion, persistence, context,
  fingerprinting, event-log, and Markdown export tests
- App-bundle property-list validation
- Strict ad-hoc code-signature verification
- Manual PDF rendering, Notes, Highlights, Agent, and detachable-window checks on
  macOS

The complete source is provided separately in `PaperCompanion-0.2.1-source.zip`.
