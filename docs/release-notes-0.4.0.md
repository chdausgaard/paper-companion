# Paper Companion 0.4.0

## Annotations in paper order

- Highlights and comments are one list, sorted by their position in the paper: page, then the text offset PDFKit assigns within the page (so two-column layouts stay in reading order), then time. Page-only comments lead their page. The Highlights tab and the "Saved comments" pane are gone; both lived in creation order.
- Click an entry to expand it to full text and jump the PDF to the passage. Click again, or press Deselect, to collapse.
- Click a highlight in the PDF to select and expand its entry; the list scrolls to it and switches to the Annotations tab if needed. The PDF does not scroll.
- Highlight rendering is incremental. Selecting used to strip and redraw every annotation on every page.
- Comments can be edited in place (pencil button on an expanded entry). Edits keep the comment's ID and are undoable; the journal records `comment_updated`.

## Keyboard

- **⌫** removes the selected highlight, or the selected page-only comment. The key is handled by the PDF view, so it only fires when a highlight was just clicked in the PDF or an entry in the list; inside a text field it still deletes text.
- **⌘↩** saves the comment: linked when there is a selection or active highlight, page-only otherwise. **⇧⌘↩** always saves page-only.

## Reading modes

- `session.json` carries `readingMode` (`preread` or `together`) and `furthestPageIndex`; both are repeated in `bridge/current-context.json`. Older sessions load as `preread`.
- **Discover together** tells the agent not to pre-read, not to convert the paper at session start, and never to read past the furthest page opened. It answers from highlight quotes with their stored surrounding text and from the pages already reached. `AGENTS.md` is regenerated on every mode change.
- The Agent tab and a new Agent menu switch modes; the status bar shows "Together" while it is on. The copied agent prompt names the mode.

## Agent replies in the app

- `agent/replies/<commentID>.md` is a new agent-owned file. The app polls `agent/` every 1.5 seconds and shows each reply under the comment it answers; the Refresh button is gone. `AGENTS.md` instructs the agent to write one for every `discuss` comment and never for margin notes.

## Annotated PDF copy

- `<paper>-annotated.pdf` in the session folder is a copy of the paper with every highlight embedded as a real highlight annotation (line-by-line quad points) and its comments as the popup text. Page-only comments are note icons in the top-left margin; margin notes are labelled and grey; agent replies are appended and attributed. Regenerated a second after any change, off the main thread, written atomically. **File → Reveal Annotated PDF**. The original PDF is still never written.

## Smaller

- Context files (`bridge/current-context.*`) are written 150 ms after the last selection or page change instead of on every event during a drag or scroll.
- Notes autosave no longer overwrites the status message.
- The detachable Notes window carries the composer and document notes; document notes use the body font rather than monospace.
- The sidebar can be widened to 640 pt.

## Library and app feedback

- Start from a persistent recent-paper library, including existing reading sessions.
- Delete a selected highlight with Backspace, together with its linked comments; Undo restores them.
- Change highlight colors from a working right-click menu, with saved colors also reflected in PDF exports.
- Check for releases automatically at launch or manually from the app menu. Download and installation are manual.
- See What’s New after a version/build change and send feature requests through a prefilled GitHub issue.
