import CryptoKit
import Foundation

public struct SessionPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var manifest: URL { root.appendingPathComponent("session.json") }
    public var highlights: URL { root.appendingPathComponent("state/highlights.json") }
    public var comments: URL { root.appendingPathComponent("state/comments.json") }
    public var notes: URL { root.appendingPathComponent("notes.md") }
    public var commentsMarkdown: URL { root.appendingPathComponent("comments.md") }
    public var documentText: URL { root.appendingPathComponent("document-text.txt") }
    public var currentContextJSON: URL { root.appendingPathComponent("bridge/current-context.json") }
    public var currentContextMarkdown: URL { root.appendingPathComponent("bridge/current-context.md") }
    public var agentInbox: URL { root.appendingPathComponent("bridge/agent-inbox", isDirectory: true) }
    public var processedInbox: URL { root.appendingPathComponent("bridge/processed", isDirectory: true) }
    public var eventLog: URL { root.appendingPathComponent("journal/events.jsonl") }
    public var sharedUnderstanding: URL { root.appendingPathComponent("agent/shared-understanding.md") }
    public var transcript: URL { root.appendingPathComponent("agent/transcript.md") }
    public var excursions: URL { root.appendingPathComponent("agent/excursions", isDirectory: true) }
    public var agentInstructions: URL { root.appendingPathComponent("AGENTS.md") }
}

public enum SessionRepositoryError: Error, LocalizedError {
    case missingManifest
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "The reading session does not contain session.json."
        case .unsupportedSchema(let version):
            return "This reading session uses unsupported schema version \(version)."
        }
    }
}

public struct LoadedSession: Equatable, Sendable {
    public var manifest: SessionManifest
    public var highlights: [HighlightRecord]
    public var comments: [CommentRecord]
    public var notes: String
    public var paths: SessionPaths

    public init(
        manifest: SessionManifest,
        highlights: [HighlightRecord],
        comments: [CommentRecord],
        notes: String,
        paths: SessionPaths
    ) {
        self.manifest = manifest
        self.highlights = highlights
        self.comments = comments
        self.notes = notes
        self.paths = paths
    }
}

public struct SessionRepository {
    public static let currentSchemaVersion = 1

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder.paperCompanion
        self.decoder = JSONDecoder.paperCompanion
    }

    public func defaultSessionsRoot() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PAPER_COMPANION_SESSION_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("Paper Companion Sessions", isDirectory: true)
    }

    public func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func sessionDirectoryName(pdfURL: URL, fingerprint: String) -> String {
        let base = pdfURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeBase = base.isEmpty ? "Paper" : base
        return "\(safeBase)-\(fingerprint.prefix(12)).reading"
    }

    public func createOrLoadSession(
        pdfURL: URL,
        title: String,
        pageCount: Int,
        extractedText: String,
        sessionsRoot: URL? = nil,
        pdfToolkitPath: String? = "/Users/christoffer/.claude/research-standards/pdf-toolkit.md"
    ) throws -> LoadedSession {
        let fingerprint = try fingerprint(of: pdfURL)
        let root = try sessionsRoot ?? defaultSessionsRoot()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionRoot = root.appendingPathComponent(
            sessionDirectoryName(pdfURL: pdfURL, fingerprint: fingerprint),
            isDirectory: true
        )
        let paths = SessionPaths(root: sessionRoot)

        if fileManager.fileExists(atPath: paths.manifest.path) {
            return try loadSession(at: sessionRoot)
        }

        try createDirectories(paths)
        let manifest = SessionManifest(
            title: title,
            sourcePDFPath: pdfURL.path,
            sourcePDFFingerprint: fingerprint,
            pageCount: pageCount,
            pdfToolkitPath: pdfToolkitPath
        )
        try writeJSON(manifest, to: paths.manifest)
        try writeJSON([HighlightRecord](), to: paths.highlights)
        try writeJSON([CommentRecord](), to: paths.comments)
        try writeText(initialNotes(title: title), to: paths.notes)
        try writeText(extractedText, to: paths.documentText)
        try writeText(initialSharedUnderstanding(title: title), to: paths.sharedUnderstanding)
        try writeText("# Agent transcript\n\n", to: paths.transcript)
        try writeText(agentInstructions(toolkitPath: pdfToolkitPath), to: paths.agentInstructions)
        try writeText(MarkdownExporter.renderComments(title: title, highlights: [], comments: []), to: paths.commentsMarkdown)
        try appendEvent(
            SessionEvent(sessionID: manifest.id, actor: "app", origin: "open_pdf", kind: "session_created"),
            to: paths.eventLog
        )

        return LoadedSession(
            manifest: manifest,
            highlights: [],
            comments: [],
            notes: initialNotes(title: title),
            paths: paths
        )
    }

    public func loadSession(at root: URL) throws -> LoadedSession {
        let paths = SessionPaths(root: root)
        guard fileManager.fileExists(atPath: paths.manifest.path) else {
            throw SessionRepositoryError.missingManifest
        }

        let manifest: SessionManifest = try readJSON(from: paths.manifest)
        guard manifest.schemaVersion == Self.currentSchemaVersion else {
            throw SessionRepositoryError.unsupportedSchema(manifest.schemaVersion)
        }
        let highlights: [HighlightRecord] = try readJSONIfPresent(from: paths.highlights) ?? []
        let comments: [CommentRecord] = try readJSONIfPresent(from: paths.comments) ?? []
        let notes = (try? String(contentsOf: paths.notes, encoding: .utf8)) ?? initialNotes(title: manifest.title)
        return LoadedSession(
            manifest: manifest,
            highlights: highlights,
            comments: comments,
            notes: notes,
            paths: paths
        )
    }

    public func saveState(
        manifest: SessionManifest,
        highlights: [HighlightRecord],
        comments: [CommentRecord],
        notes: String,
        paths: SessionPaths
    ) throws {
        try createDirectories(paths)
        try writeJSON(manifest, to: paths.manifest)
        try writeJSON(highlights, to: paths.highlights)
        try writeJSON(comments, to: paths.comments)
        try writeText(notes, to: paths.notes)
        try writeText(
            MarkdownExporter.renderComments(title: manifest.title, highlights: highlights, comments: comments),
            to: paths.commentsMarkdown
        )
    }

    public func writeCurrentContext(_ context: CurrentContext, paths: SessionPaths) throws {
        try writeJSON(context, to: paths.currentContextJSON)
        try writeText(MarkdownExporter.renderCurrentContext(context), to: paths.currentContextMarkdown)
    }

    public func appendEvent(_ event: SessionEvent, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        lineEncoder.dateEncodingStrategy = .iso8601
        var data = try lineEncoder.encode(event)
        data.append(0x0A)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public func writeText(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        try data.write(to: url, options: .atomic)
    }

    private func createDirectories(_ paths: SessionPaths) throws {
        let directories = [
            paths.root,
            paths.highlights.deletingLastPathComponent(),
            paths.currentContextJSON.deletingLastPathComponent(),
            paths.agentInbox,
            paths.processedInbox,
            paths.eventLog.deletingLastPathComponent(),
            paths.sharedUnderstanding.deletingLastPathComponent(),
            paths.excursions
        ]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func readJSONIfPresent<T: Decodable>(from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readJSON(from: url)
    }

    private func initialNotes(title: String) -> String {
        """
        # Notes: \(title)

        Use the Notes tab for document-level notes. Page-only comments, highlighted passages, and linked comments are exported to `comments.md`.

        """
    }

    private func initialSharedUnderstanding(title: String) -> String {
        """
        # Agent's reading: \(title)

        The agent's map of the paper, revised in place as understanding changes.
        Everything below is the agent's inference unless a quotation and page
        number are given. Your own comments and positions live in
        `agent/transcript.md`; workshop comments are generated on request.

        Sections 1 to 6 are meant to stay short enough to scan. Detail belongs
        under Reference detail or in the transcript.

        ## In one paragraph

        ## The argument, as the paper makes it

        ## What the design actually does

        For each specification: unit of analysis, sample, outcome, estimator,
        fixed effects, clustering, and what variation identifies the estimate.

        ## Claims versus evidence

        | Claim | Where it is made | What actually supports it | How well |
        | --- | --- | --- | --- |

        Include claims from the abstract and introduction, not only from the
        results sections. Mismatches between what is asserted and what is
        estimated belong here.

        ## Where it is most vulnerable

        Ranked by how much each threatens the central claim.

        ## Open questions

        Mark items only the user can settle, such as anything readable only from
        a figure.

        ## Reference detail

        Long-form notes for the agent: control lists, validation numbers, exact
        variable names, page anchors.

        """
    }

    private func agentInstructions(toolkitPath: String?) -> String {
        let toolkit = toolkitPath ?? "the user's configured PDF toolkit"
        return """
        # Paper Companion reading-session protocol

        This directory is a live, local reading session. Preserve the user's exact wording and keep paper text, user comments, and agent inferences distinct.

        ## Read first

        1. Read `session.json`.
        2. Read `bridge/current-context.json` for the active page or selection.
        3. Read `agent/shared-understanding.md` only when cumulative context is needed. Read its Reference detail section only when you need a specification or a number.
        4. Use the PDF extraction protocol at `\(toolkit)` for substantive PDF reading. Do not treat `document-text.txt` as authoritative for complex layouts, tables, figures, or scans.

        ## Ownership

        - The app owns `session.json`, `state/`, `journal/`, `notes.md`, `comments.md`, `document-text.txt`, and `bridge/current-context.*`. Do not edit them.
        - You may edit only `agent/transcript.md`, `agent/shared-understanding.md`, and files below `agent/excursions/`.
        - Preserve dictated comments verbatim in `agent/transcript.md`. Put your interpretation in a separate labeled paragraph.
        - This file is generated by the app. To change the protocol for future sessions, edit the template in `Sources/PaperCompanionCore/SessionRepository.swift`, not the copy inside a session.

        ## Session start

        Do these before the user starts reading. Do not make the user drive the plumbing.

        1. **Arm a comment watcher.** Poll `journal/events.jsonl` for lines whose `kind` starts with `comment` or `note`, emitting one event per new record. Keep a change-hash of `state/comments.json` as a fallback in case a write is not journalled. A background monitor is correct here; the user should never have to ping you that a comment exists.
        2. **Offer a pre-read.** A named, resumable sub-agent that reads the paper and fills `agent/shared-understanding.md` is worth the tokens: it grounds every later interpretation and keeps the paper text out of the main context. It must leave `## User's emerging assessment` and `## Recurring concerns and cross-links` empty. Propose it and wait for approval.
        3. **Convert once.** For a full read-through, run `pdf2md` a single time so sub-agents read a cache instead of re-extracting. Tell the user where the file landed and do not delete it without asking.
        4. **Orient, do not ingest.** `pdfheadings` and `pdfcount --by-page` in the main context are fine. Page text is not: delegate `pdfread` and cache reads to sub-agents.

        ## The three agent files

        Each has one job. Do not let them blur, which is the failure mode that makes the reading tab unreadable.

        - **`agent/shared-understanding.md` is your reading of the paper**, and it is a surface the user opens to see how you understand the argument. Revise it **in place** as your understanding changes. Do not append to it — a map that is only appended to becomes sediment, and a long one does not get read. Keep everything above Reference detail short enough to scan.
        - **`agent/transcript.md` is the record.** Every comment verbatim with its anchor, your response, and your interpretation kept in a separate labeled paragraph. Append-only. When the user explicitly endorses a point, mark it `ENDORSED` with the date **here** — his positions belong in the record, not in your map.
        - **`agent/excursions/` holds generated deliverables**, including the workshop synthesis. Do not accumulate workshop questions anywhere else; produce them when asked, from the transcript.

        Fill the map early, from a pre-read, so that comments can be interpreted against the real design rather than the abstract. Then keep it honest: when a section turns out to be wrong, rewrite that section rather than adding a correction below it.

        The Claims versus evidence table is the highest-value section. Populate it from the abstract and introduction as well as the results, and record any gap between what is asserted and what is estimated. Mismatches of that kind are frequently the strongest findings available and are easy to miss when reading section by section.

        ## Interaction policy

        - Default to Clarify mode: ask only when two plausible interpretations would materially change the criticism or final synthesis.
        - Ask at most one immediate clarification per comment. Defer minor ambiguity.
        - Cite page labels and stable highlight IDs from current context.
        - Do not silently resolve uncertainty.
        - Treat unpublished workshop papers as confidential. Do not send titles, authors, quotations, or paper text to web research without explicit permission. For an excursion, default to a decontextualized research question.

        ## Working with this user

        - **Reviewer 2 mode, but fair.** Most skeptical plausible reading by default. Fairness is part of the job, not a softening of it: when the paper has a real defence, say so and say what it protects. Record genuine design virtues as positives so they survive into the synthesis.
        - **Be concise.** He often reads in a rush and skims replies. Lead with the answer, then the reasoning. Long replies get skipped.
        - **He will not respond to everything.** Silence is not rejection. Bank unresponded points and resurface them when they become relevant to a later comment.
        - **Endorsement gate.** Nothing enters `## User's emerging assessment` until he explicitly endorses it. Until then it lives in `agent/transcript.md`. Record his position as a paraphrase attributed to him, kept separate from agent elaboration.
        - **Log comments agent-side. Never hand him text to paste.** He finds pasting into the app cumbersome. The record lives in `agent/transcript.md`; spoken versions are produced from it on request. He may deliver comments by typing into the app, which supplies an exact highlight anchor, or by saying them in conversation, in which case anchor from `bridge/current-context.json`. Both are equally valid inputs.
        - **Correct him when he is wrong, briefly.** He would rather be corrected here than at the workshop. Give the correction, then the version of his point that survives.
        - **Your job is to test his comments, not to validate them.** He is explicit that many are loose thoughts he wants evaluated. The worst outcome he can imagine is arriving with overconfident, tangential, uncharitable comments. A session where every comment is upgraded into an argument has failed him, however good each individual analysis was.
        - **No praise. No rankings that inflate.** Do not tell him a comment is strong, sharp, or the best so far. If several comments are called the best in one session, that is escalation, not calibration, and it destroys the signal he needs. State what a comment does and does not establish, then move on.
        - **Say plainly when a comment is not worth raising.** Weak, tangential, or already-conceded points must be named as such at the time, not silently carried to the synthesis. Every session should be expected to produce some comments that get cut; if none did, you were not evaluating.
        - **Test his premises before building on them.** Check whether the paper already addresses the point, whether the criticism survives the most charitable reading, and whether he is over-claiming. Flag the specific sentence that would over-reach if spoken aloud.
        - **Draw connections he cannot see.** Testing is one half; the other is noticing when three separate comments are one argument, when an earlier comment predicted a later passage, and what the paper's own text implies that he has not yet joined up. He values this and it is not in tension with rigour.
        - **Proposing sub-agents is not launching them.** State the plan and wait. Always name them so they stay resumable for follow-up questions.

        ## Verification discipline

        Keep three epistemic statuses distinct in every claim, in the transcript and in conversation:

        1. **Verified verbatim** — quoted from the PDF, with a page number.
        2. **Agent inference** — reconstruction, arithmetic, or extrapolation. Label it.
        3. **The user's own reading** — especially figures, which you cannot read. Attribute it to him.

        Sub-agent reports are evidence, not fact. Spot-check load-bearing claims against the PDF before relaying, and be especially careful with absence claims such as "X is not controlled anywhere", which a summary can get wrong. Prefer the weaker defensible formulation: "unsupported by anything the paper reports" beats "contradicted" when both fit.

        ## Deliverable

        When the user asks for a synthesis, write it to `agent/excursions/` — the only place you may create new files — and offer to copy it into the folder holding the PDF. Shape it as:

        - **Three to five comments, fully drafted to be spoken**, ranked by how much each threatens the central claim. He will not have room for more.
        - **A reserve list**, one line each, for discussion or written feedback.
        - **What to concede** — real strengths of the paper. He wants to give the benefit of the doubt and this is how.
        - **What was cut, and why** — every comment that did not survive, named, with the reason. This section is not optional and it is not padding: it is how he learns which of his instincts to trust, and it is the check against arriving with tangential comments. A synthesis in which nothing was cut should be re-examined before it is delivered.
        - **Evidence status** — what is verbatim, what is his own reading, what is inference, what is unverified background knowledge that must not be asserted, and anything now known to be unreliable. This exists so he does not overstate anything in the room.

        Under each drafted comment, add a **where you would be over-claiming** note whenever a plausible stronger phrasing would not survive scrutiny — name the sentence to avoid and why the authors would defeat it. Add a **delivery note** where the framing matters, in particular when he first raised a point as confusion; asked as a question about the design, such points get the design explained back and the substance is lost.

        Phrase every drafted comment as a question or an offer. No accusations. Where a finding could sound like one, build in a genuine escape hatch for the authors.

        ## Environment gotchas

        - **Figures cannot be extracted as text, but they can be rendered and looked at.** `pdftoppm -f N -l N -r 170 -png file.pdf out/pN` produces a page image a sub-agent can open with the Read tool. Audit which pages need it first with PyMuPDF: `page.get_images()` finds true rasters, `len(page.get_drawings())` above ~100 finds vector plots. Vector figures render crisply and give reliable panel titles, axis labels, and interval positions.
        - **A rendered-figure reading is the weakest evidence in the session and must never outrank the user's.** In the CBS session of 2026-08-08 the pre-read agent placed an event-study drop one period later than it was, which inverted the substantive reading of the paper's main result. When a sub-agent's figure reading and the user's disagree, his wins without argument, and the sub-agent's other figure readings become unusable — say so rather than quietly keeping them. Never let a coefficient read off a plot enter a drafted comment as a number.
        - **The figure's own text layer is often extractable even when the plot is not.** Axis labels, tick values, panel headings, and captions frequently sit in the surrounding highlight `prefix`/`suffix`, and they are verbatim evidence. Harvest them before asking him to read anything: an axis labelled "ATT on ln Employees" with ticks at 0.00 and −0.08 settles both the transformation and whether any estimate exceeds baseline.
        - **Toolkit binaries are not on PATH** in a non-login shell. Export `PATH="$HOME/.local/bin:$PATH"` before calling `pdfheadings`, `pdfread`, `pdfgrep`, `pdfcount`, or `pdf2md`.
        - **`pdf2md` with no output path writes beside the source PDF**, inside the user's own folder. Say so; it is his directory, not scratch space.
        - **`state/comments.json` is written before `journal/events.jsonl`.** A read landing between the two can show a comment that appears missing. Never infer a deletion from a single read — re-check the journal before recording one.
        - **`comments.md` puts page-level comments last.** Comments with no highlight go under `## Standalone and orphaned comments` at the end of the file, after every page section. Parsing "the last page section" is unreliable; index by comment ID from `state/comments.json`.
        - **Highlights can span footnotes and page furniture.** A quoted passage may contain interleaved footnote text and a bare page number. Note it and quote the intended text.
        - **`pageIndex` is zero-based over PDF pages; `pageLabel` is the printed number.** They diverge whenever there is unnumbered front matter. Cite the label the user sees, and convert when referring to toolkit page numbers.
        - **Establish the page offset empirically at session start, before citing anything.** `pdfgrep`, `pdfread` and `pdfheadings` all report toolkit page numbers, which are one higher than the printed label for every page after an unnumbered title page. Quoting grep output directly is the easy mistake and it puts a wrong page number in front of the authors. Derive the map once with PyMuPDF — read the trailing number from each page's text and compare with the index — then record it at the top of `agent/transcript.md` and cite printed labels everywhere.
        - **Comments can arrive mid-turn.** Handle the queued comment before replying to anything else.

        ## Suggested transcript entry

        ```markdown
        ## Comment — [timestamp]
        Anchor: page N, highlight UUID

        **User (verbatim):** ...

        **Agent interpretation (provisional):** ...

        **Clarification:** none | question...
        ```
        """
    }
}

extension JSONEncoder {
    static var paperCompanion: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var paperCompanion: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
