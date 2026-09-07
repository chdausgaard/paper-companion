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

Every command below is typed into Terminal, the macOS command-line app. It is
in Applications → Utilities, or press ⌘Space and type "Terminal". Paste one
block at a time and press Return; some will print a lot of output, which is
normal.

If you have never built anything on this Mac, install Apple's compiler tools
first. This is a one-time system dialog, roughly 1.5 GB, and needs no Apple ID
or payment. It is not the full Xcode application. If they are already
installed, the command simply says so and does nothing.

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/chdausgaard/paper-companion
cd paper-companion
./scripts/package-app.sh --install
```

About a minute of build output scrolls past, ending in a line beginning
`Installed PaperCompanion`. The app is then in `/Applications` — open it from
there, or with ⌘Space.

### Updating

Quit Paper Companion first. Then, from the same `paper-companion` folder you
cloned into:

```bash
git pull
./scripts/package-app.sh --install
```

If you forget to quit it, the script says so and stops, rather than replacing
the running app and corrupting the install. Nothing you have written is
affected either way: reading sessions live in `~/Documents/Paper Companion
Sessions` and are never touched by an update.

## Core workflow

1. Open a PDF with **⌘O**.
2. Select text and press **⇧⌘H**, or enable **Auto-highlight selections** for drag-to-highlight reading. Click a highlight in the PDF or in the list and press **⌫** to remove it and its linked comments. Right-click a highlight to change its color or delete it; colors are saved and included in the annotated PDF. **⌘Z** restores the latest highlight or comment change.
3. Type a comment in the composer under the Annotations list and press **⌘↩**. With a selection or an active highlight it saves linked to that passage; otherwise it is anchored to the current page. **⇧⌘↩** forces a page-only comment.
4. Press **⇧⌘M** for a **margin note** — anchored and recorded like any comment, but journalled so the agent files it without responding. This is for the reactions that are not worth a conversation: *nice explanation*, *this table is unreadable*, *lost the thread here*. They are read back at synthesis time, where a cluster of them on one section is itself a finding.
5. The **Annotations** list shows every highlight and comment in paper order — the order of the passages, not the order you wrote them. Click an entry to expand it to full text and scroll the PDF to its passage; click a highlight in the PDF to select and expand its entry. Expanded comments can be edited in place with the pencil button. Agent replies appear under the comment they answer.
6. Keep document-level, unanchored Markdown notes in the Notes tab. The detachable Notes window carries the composer and document notes so the sidebar can stay on the list.
7. Choose a **reading mode** in the Agent tab (or the Agent menu) and copy the agent prompt into your existing agent client.

### Reading modes

- **Agent pre-reads** (default): the agent reads the whole paper first and fills `agent/shared-understanding.md` before you comment, so comments are interpreted against the real design.
- **Discover together**: the agent reads only what you have reached. It answers from each highlight's quote and the stored text around it, may read the pages up to the furthest one you have opened, and never reads ahead. Its map of the paper fills in as you get there. Switch at any time; the mode is written to `session.json` and `bridge/current-context.json`, and `AGENTS.md` is regenerated so a running agent picks the change up.

The original PDF is never written or modified. Highlight rendering comes from sidecar records.

## Reading sessions

Sessions are created at:

```text
~/Documents/Paper Companion Sessions/<paper>-<fingerprint>.reading/
```

Important files:

- `notes.md`: your unanchored, document-level free-form notes.
- `comments.md`: generated readable projection of highlights, linked comments, and page-only comments.
- `<paper>-annotated.pdf`: a copy of the paper with highlights and comments embedded as standard PDF annotations, so they show in Preview, Acrobat, Skim, or a Zotero import. Regenerated about a second after any highlight, comment, or agent reply changes; **File → Reveal Annotated PDF** finds it. It is a projection, not a record: edits made to it in other apps are not read back.
- `state/comments.json`: structured source of truth for both comment types.
- `state/highlights.json`: app-owned highlight geometry and exact quotations.
- `bridge/current-context.json`: small, current page/selection snapshot for agents.
- `AGENTS.md`: instructions for an external filesystem-capable agent.
- `agent/transcript.md`: agent-owned verbatim comment transcript.
- `agent/replies/<commentID>.md`: agent-owned reply to one comment. The app polls this folder and shows each reply under its comment.
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
- Highlights are embedded only into the annotated copy in the session folder, never into the original, and annotations made in other apps are not imported.
- Agent integration is file-based. Paper Companion does not start, authenticate, or message an agent.
- Voice capture stays in your existing agent/client.
- Agent-owned files are polled every 1.5 seconds rather than watched; a reply can take that long to appear.
- Direct external edits to `notes.md` while the app is open can be overwritten by a later in-app save.
- The app does not yet re-anchor sidecar highlights if the source PDF changes; the source fingerprint creates a separate session instead.

## Privacy

The app itself performs no network requests. For unpublished workshop papers, remember that asking an external agent to read the PDF or quotations may send that material to the agent provider. The generated agent instructions default literature excursions to decontextualized questions unless you explicitly permit sharing paper identity or text.

### Library, updates, and feedback

The opening screen lists up to 50 recent papers. Existing reading sessions are imported on first use. Choose a paper to resume its saved reading position, highlights, and notes, or use the **Library** toolbar button to return to the list. Removing a recent entry leaves the PDF and session files untouched.

Paper Companion checks public GitHub releases at launch. **Paper Companion → Check for Updates…** checks manually. An available update opens the release page for download and manual installation; this is not an automatic installer. **What’s New** appears on the first launch of this feature and after a version/build change, and is also available from the app menu.

The **Request Feature** toolbar button (also in **Help**) opens a prefilled GitHub issue. You can review and submit it in your browser; a GitHub account is required.
