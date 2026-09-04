# Paper Companion

Paper Companion is a local-first macOS reader for academic PDFs. It combines native PDFKit reading and non-destructive highlights with transparent Markdown/JSON session files that an external Codex or Claude agent can understand while you read.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac supported by the installed Swift toolchain
- Xcode Command Line Tools to build from source

## Install

There is no download. You build Paper Companion on your own Mac, which takes
about a minute and avoids Gatekeeper entirely: macOS quarantines applications
that arrive over the network, not ones you compile yourself, so the app you
build here opens on a double-click with no warning. A downloaded build would
not, because this prototype is ad-hoc signed rather than Developer ID signed
and notarized.

If you have never built anything on this Mac, install Apple's compiler tools
first. This is a one-time system dialog, roughly 1.5 GB, and needs no Apple ID
or payment. It is not the full Xcode application.

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/chdausgaard/paper-companion
cd paper-companion
./scripts/package-app.sh --install
```

The app lands in `/Applications`. To update later, quit it, then `git pull` and
run the same command again — the script refuses to replace a running copy
rather than corrupting the install.

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

The protocol points the agent at two local references, both resolved from the current user's home directory at session load and both optional:

- `~/.claude/research-standards/pdf-toolkit.md` — the authoritative path for deep PDF extraction.
- `~/docs/causal-inference/` — routed through before any comment that turns on an identifying assumption.

When a directory is missing, that section degrades to the discipline without the routing rather than naming a path that does not exist on this machine. Nothing is hardcoded to one user's home. `document-text.txt` is a convenient PDFKit extraction and can have incorrect reading order for columns, tables, or figures.

## Build and test

```bash
swift build
swift test
```

Package a local `.app`:

```bash
scripts/package-app.sh                 # build and package; prints the bundle path
scripts/package-app.sh --install       # ...and copy it to /Applications
scripts/package-app.sh --help          # all options
UNIVERSAL=1 scripts/package-app.sh     # arm64 + x86_64, for a bundle you hand to someone else
```

`--install` replaces an existing Paper Companion without asking, since
reinstalling over the previous version is the normal case, but refuses to
delete any other application that happens to share the name unless you pass
`--force`. It also refuses while the app is running.

A plain build is native-only and will not launch on the other architecture, so
use `UNIVERSAL=1` for anything leaving this machine. The script prints the
architectures it actually bundled.

The bundle is built under `~/Library/Caches/PaperCompanion/build` rather than
inside the repo on purpose. An `.app` anywhere in the home folder's indexed
areas is registered by LaunchServices, so Alfred and Spotlight offer the build
alongside the installed copy. `~/Library` is not scanned, which keeps
`/Applications/PaperCompanion.app` the only hit. Pass a path as the first
argument to write the bundle elsewhere.

The version comes from `VERSION`; bump `CFBundleVersion` in
`support/Info.plist.in` alongside it.

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
