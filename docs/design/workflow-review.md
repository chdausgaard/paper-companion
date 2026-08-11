# Workflow design handoff: agent-assisted academic paper reading

## Product thesis

The useful product is a **shared reading session**, not an AI chat embedded in a PDF reader. The app should keep the PDF, highlights, and the user's exact comments authoritative; an external filesystem-capable agent should add interpretations, clarifications, synthesis, and literature excursions without rewriting the user's record.

The core contract is:

1. The app always knows what passage/page the user is looking at.
2. The user can dictate a comment in an existing agent conversation without restating the passage.
3. The agent preserves the comment verbatim, separately records its interpretation, and asks only consequential clarifying questions.
4. Every claim remains traceable to a page/highlight/comment or an external source.
5. The user's original PDF and converted paper text remain immutable derived/source material; session notes live separately.

## Recommended MVP experience

### Main window

- Center: native PDFKit reader with search, page navigation, zoom, and text selection.
- Right inspector, with optional detached window:
  - **Notes**: chronological comments and unresolved clarifications.
  - **Highlights**: filterable list of highlights, each showing page, excerpt, and linked comments.
  - **Session**: evolving assessment, open questions, and excursion status.
- A compact footer shows `Page`, current selection/highlight ID, and agent-bridge state (`Context ready`, `Agent update`, `Needs clarification`).
- Do not put a second chat UI or model credentials in v1. Add an **Open agent workspace** action that reveals/opens the session folder and copies a one-sentence prompt identifying it.

### Highlight and comment flow

1. Selecting PDF text shows `Highlight` and `Highlight + note`.
2. Creating a highlight immediately persists:
   - exact selected text;
   - zero-based PDF page index plus human-facing page label/number;
   - PDFKit selection rectangles/quadrilaterals;
   - prefix/suffix text for anchoring and agent context;
   - document fingerprint and timestamps.
3. The new highlight becomes `active`. The app atomically refreshes `bridge/current-context.json` and a human-readable `bridge/current-context.md`.
4. The user can type a note in the app or dictate to the external agent. In either case, the **original wording is stored verbatim** in a new comment record. Editing a comment creates a revision; it does not destroy the original.
5. An agent response may add an interpretation, clarification, relation to another passage, or excursion request. These are separate records with explicit provenance and never replace the user's words.
6. Clicking any note navigates back to and briefly flashes its highlight. Clicking a highlight shows all comments and clarifications linked to it.

### When there is no text selection

Voice comments such as “The identification argument on this page is unclear” should still work. `current-context` should always contain the visible page, current page text if available, the most recent active highlight, and nearby headings. The agent links the comment to the page (`anchor_type: page`) and can later attach it to a highlight if the user clarifies.

### External voice-agent flow

This assumes the voice conversation is with a local/filesystem-capable Codex or Claude agent. Voice transcription itself is outside the app.

- The session folder contains a small `AGENTS.md` telling the external agent exactly which files it may read/write and how to use the PDF toolkit.
- On starting work, the user says: “Use the open Paper Companion session and capture my comments as we go.” The agent reads only the session manifest, current context, and compact shared understanding initially.
- For each dictated comment the agent:
  1. writes the transcription as a verbatim user-comment event;
  2. links it to `active_highlight_id` or the visible page;
  3. records a separate, concise interpretation;
  4. either acknowledges silently/briefly, asks one necessary question, or starts a requested excursion;
  5. updates shared understanding only when the new comment materially changes it.
- The app watches an agent inbox directory and renders validated updates. Agents should never edit app-owned projection files directly.
- Useful voice commands: `capture that`, `link that to the last highlight`, `park the question`, `let's unpack this`, `start an excursion on …`, `what do you think I mean so far?`, and `summarise my view of the methods`.

An external voice tool without filesystem access cannot provide this workflow automatically. The honest fallback is a **Copy context** button that places the current excerpt plus stable IDs on the clipboard; the agent's response can later be pasted/imported. Do not imply that an arbitrary ChatGPT voice conversation can see local files.

## Clarification policy: preserve flow

Use three interaction modes, switchable globally or by voice command:

- **Capture**: store comments and queue ambiguities; never interrupt.
- **Clarify** (recommended default): ask only when two plausible interpretations would materially change the criticism, proposed question, or final synthesis.
- **Discuss**: actively probe implications, counterarguments, and links across the paper.

Default clarification rules:

- Ask at most one immediate question per comment.
- Prefer a short either/or formulation plus a free-form option.
- Do not interrupt to fix wording, request optional detail, or demonstrate comprehension.
- If the user says `park it`, set the clarification to `deferred` and continue.
- Batch low-urgency questions for a page/section boundary. Display an unobtrusive unresolved count rather than modal prompts.
- Every clarification stores: the ambiguous source comment, the agent's candidate interpretations, why the distinction matters, the exact question, the user's verbatim answer, and the resolved interpretation.
- Unanswered questions must remain visible in final outputs; never silently choose an interpretation.

## Structured record model

Use stable ULID/UUID IDs, ISO-8601 timestamps, and a `schema_version`. Store an append-only event log for audit/recovery, while generating convenient JSON/Markdown projections. Each event includes `actor` (`user`, `app`, `agent:<name>`), `origin` (`typed`, `voice_transcript`, `pdf_selection`, `agent_inference`, `web_research`), and `session_id`.

### Highlight

Required fields:

```json
{
  "id": "H-…",
  "document_id": "D-…",
  "page_index": 6,
  "page_label": "7",
  "quote": "exact selected text",
  "prefix": "preceding context",
  "suffix": "following context",
  "rects": [{"x": 0.1, "y": 0.3, "w": 0.5, "h": 0.04}],
  "color": "yellow",
  "created_at": "…",
  "deleted_at": null
}
```

Normalize rectangles to page bounds so resize/rotation does not break them. Preserve deleted highlights as tombstones because comments may still refer to them. Store highlights as sidecars and never modify the source PDF in v1.

### User comment

```json
{
  "id": "C-…",
  "anchor": {"type": "highlight", "id": "H-…"},
  "verbatim": "user's exact dictated or typed words",
  "capture_method": "voice_transcript",
  "revision_of": null,
  "created_at": "…",
  "tags": ["identification"],
  "status": "captured"
}
```

The app may show cleaned prose, but any cleanup must be an explicit derivative field or revision. Never overwrite `verbatim`.

### Agent interpretation

```json
{
  "id": "I-…",
  "comment_id": "C-…",
  "interpretation": "concise statement of what the agent thinks the user means",
  "confidence": "low|medium|high",
  "status": "provisional|confirmed|rejected|superseded",
  "agent": "…",
  "created_at": "…"
}
```

The UI must visually distinguish user words, paper text, and agent interpretation. A `confirmed` interpretation requires user confirmation or a resolving clarification, not merely agent confidence.

### Clarification

Required fields: `id`, `comment_ids`, `candidate_interpretations`, `question`, `why_it_matters`, `urgency` (`now`, `section_end`, `session_end`), `status` (`open`, `deferred`, `resolved`, `dismissed`), `verbatim_answer`, `resolved_interpretation_id`, and timestamps.

### Shared understanding

Keep a compact, revisioned Markdown document with these fixed sections:

1. Paper's thesis and mechanism
2. Design/evidence as currently understood
3. User's emerging assessment
4. Recurring concerns and cross-links
5. Possible workshop questions
6. Unresolved ambiguities
7. Agent hypotheses/counterarguments

Every bullet should cite `[p. 7]`, `[H-…]`, `[C-…]`, or `[E-…]`. Separate what the paper says, what the user thinks, and what the agent infers. Keep a revision history or generate it from events. This is a compact working memory, not a replacement for the chronological record.

### Literature excursion

Required fields: `id`, `originating_comment_id`, `originating_highlight_id`, `question`, `deliverable`, `scope`, `allowed_sources`, `confidentiality`, `shared_context_level`, `status`, `assigned_agent`, timestamps, and `result_path`.

Statuses: `proposed`, `queued`, `running`, `needs_input`, `complete`, `failed`, `cancelled`.

For unpublished/confidential papers, default `shared_context_level` to `derived_question_only`; do not send the title, author, full text, or a quote to web research unless the user explicitly allows it. Results must keep citations, retrieval dates, limitations, and a clear distinction between source findings and agent inference. Never merge an excursion result into the user's assessment automatically.

## Suggested session folder and ownership

```text
Reading Session/
├── AGENTS.md                       # generated bridge protocol
├── session.json                    # app-owned manifest; PDF path + SHA-256
├── journal/events.jsonl            # append-only canonical audit trail
├── state/highlights.json           # app-generated projection
├── state/comments.json             # app-generated projection
├── bridge/current-context.json     # app-owned; atomic replace
├── bridge/current-context.md       # app-owned human-readable view
├── bridge/agent-inbox/             # one immutable JSON command per file
├── bridge/processed/               # validated inbox commands + errors
├── comments.md                     # app-generated readable projection
├── shared-understanding.md         # agent-authored, revisioned via events
└── excursions/E-…/
    ├── request.json
    └── result.md
```

Avoid concurrent edits by declaring ownership:

- App owns manifest, event log, state projections, current context, and rendered comments.
- Agent writes one new immutable file per operation to `bridge/agent-inbox/` using a temporary filename followed by atomic rename.
- The app validates, records, and moves each command to `processed/`; malformed commands remain visible with an error rather than being discarded.
- Excursion workers write only inside their own excursion directory.
- Shared understanding updates should arrive as inbox commands or versioned full snapshots, not uncontrolled edits to a shared file.

## Integration with the existing PDF toolkit

The supplied `/Users/christoffer/.claude/research-standards/pdf-toolkit.md` is directly useful and should be referenced by the generated session `AGENTS.md` rather than copied into app logic.

Key implications:

- This is sustained, multi-section paper work, so the external agent should run `pdf2md` once at the start and use the cached Markdown thereafter.
- The main conversational agent should never ingest full PDF page text. It may use `pdfheadings`, `pdfgrep`, `pdfcount`, and `pdf2md`; page text/full cached Markdown should be read by a focused sub-agent, which returns concise results.
- `pdfgrep` locates pages; it is not evidence for an answer. Use `pdfread` only in a sub-agent and on surgical page ranges.
- Respect the existing library: converted papers belong in `~/Documents/pdf-library/papers/`, with deterministic filenames, frontmatter, deduplication, and `_index.md` maintenance.
- Do not place comments in the converted paper Markdown. Session notes should be separate; if exported to the Obsidian vault, use the toolkit's `notes-{paperfilename}.md` convention and include the paper wikilink.
- The source PDF and cached paper Markdown are immutable inputs/derived artifacts. Highlights and comments are sidecars.

The session manifest should therefore store pointers such as `source_pdf_path`, `source_pdf_sha256`, and optional `library_markdown_path`; it should not duplicate or alter the user's PDF library content.

## End-of-session outputs

Generate, but never conflate:

- **Chronological comments**: verbatim comments, linked excerpts/pages, clarifications, and confirmed interpretations.
- **Thematic notes**: theory, design, evidence, exposition, and literature connections.
- **Shared-understanding snapshot**: the compact living document described above.
- **Workshop brief**: main assessment, strongest questions, and unresolved issues.
- **Excursion index**: question, status, and cited result link.

Each generated statement should retain stable IDs so the user can move from synthesis back to the exact PDF location and original words.

## MVP boundaries and acceptance checks

Deliberately exclude embedded chat/voice, cloud accounts, PDF mutation, collaborative sync, automated internet search, and publication/distribution.

The MVP is credible only if all of these work:

1. Reopening a session restores PDF position, highlights, comments, and the active context.
2. A highlight across multiple lines/rectangles navigates correctly after window resizing and page rotation.
3. A dictated comment is preserved verbatim and visibly distinct from agent interpretation.
4. Page-only comments work when no text is selected.
5. An external agent can read current context, submit a linked comment/interpretation via inbox, and see it appear without editing app-owned files.
6. Deferred clarifications survive restart and appear in final output.
7. Two simultaneous excursion results cannot corrupt the journal or each other.
8. The original PDF and PDF-library Markdown hashes do not change.
9. A confidential-session excursion defaults to a decontextualized research question and requires consent before sharing excerpts/identity.
10. Exported Markdown retains page numbers and stable highlight/comment/excursion IDs.

## One important product decision

Make the app's value independent of any one agent vendor. The durable interface should be ordinary files plus a small, documented command schema. Codex/Claude-specific launch conveniences can sit on top. That preserves the user's notes, makes the workflow auditable, and allows a better agent to be substituted later without migrating the reading record.
