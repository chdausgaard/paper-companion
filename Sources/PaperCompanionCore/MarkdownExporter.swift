import Foundation

/// Writes `comments.md` and `bridge/current-context.md`, which the agent reads.
///
/// Text that comes from the PDF (quotes, selections, surrounding text, page
/// labels, the title from its metadata) is never allowed to look like
/// structure the app wrote: labels and the title are flattened onto the line
/// that uses them, and longer text goes in a block quote it cannot leave. The
/// user's own comment text is written exactly as he typed it.
public enum MarkdownExporter {
    public static func renderComments(
        title: String,
        highlights: [HighlightRecord],
        comments: [CommentRecord]
    ) -> String {
        var lines = [
            "# Reading comments: \(oneLine(title))",
            "",
            "Generated from Paper Companion sidecar records. The original PDF is not modified.",
            ""
        ]

        let activeHighlights = highlights
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let activeComments = comments.filter { $0.status != "deleted" }

        for highlight in activeHighlights {
            if highlight.isRegion {
                lines.append(contentsOf: regionSection(highlight))
            } else {
                lines.append("## Page \(oneLine(highlight.pageLabel)) · Highlight `\(highlight.id.uuidString)`")
                lines.append("")
                lines.append(contentsOf: blockquote(highlight.quote))
                lines.append("")
            }

            let linked = activeComments
                .filter { $0.highlightID == highlight.id }
                .sorted { $0.createdAt < $1.createdAt }
            if linked.isEmpty {
                lines.append("_No linked comment._")
                lines.append("")
            } else {
                for comment in linked {
                    lines.append("### \(label(for: comment)) `\(comment.id.uuidString)`")
                    lines.append("")
                    lines.append(comment.verbatim)
                    lines.append("")
                }
            }
        }

        let activeIDs = Set(activeHighlights.map(\.id))
        let standalone = activeComments
            .filter { comment in
                guard let highlightID = comment.highlightID else { return true }
                return !activeIDs.contains(highlightID)
            }
            .sorted { $0.createdAt < $1.createdAt }
        if !standalone.isEmpty {
            lines.append("## Standalone and orphaned comments")
            lines.append("")
            for comment in standalone {
                let page = comment.pageLabel.map { " · Page \(oneLine($0))" } ?? ""
                lines.append("### \(label(for: comment)) `\(comment.id.uuidString)`\(page)")
                lines.append("")
                if let highlightID = comment.highlightID {
                    lines.append("_Original highlight `\(highlightID.uuidString)` is no longer active._")
                    lines.append("")
                }
                lines.append(comment.verbatim)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderCurrentContext(_ context: CurrentContext) -> String {
        var lines = [
            "# Current reading context",
            "",
            "- Session: `\(context.sessionID.uuidString)`",
            "- Page: \(oneLine(context.pageLabel)) (index \(context.pageIndex))",
            "- PDF: `\(context.sourcePDFPath)`",
            "- Source fingerprint: `\(context.sourcePDFFingerprint)`",
            "- Text status: \(context.textStatus)",
            "- Reading mode: \(context.readingMode.rawValue)",
            "- Furthest page index reached: \(context.furthestPageIndex)",
            "- Updated: \(ISO8601DateFormatter().string(from: context.updatedAt))"
        ]
        if let highlightID = context.activeHighlightID {
            lines.append("- Active highlight: `\(highlightID.uuidString)`")
        }
        if context.activeRegion != nil {
            lines.append("- Active anchor: region (a box the user drew on the page; see Active region)")
        }
        lines.append("")

        if let region = context.activeRegion {
            lines.append("## Active region")
            lines.append("")
            lines.append("The user drew a box on page \(oneLine(context.pageLabel)), usually around a figure or table. Paths are relative to the session folder.")
            lines.append("")
            lines.append(contentsOf: regionFacts(region, id: context.activeHighlightID))
        } else if let selectedText = context.selectedText, !selectedText.isEmpty {
            lines.append("## Exact selection")
            lines.append("")
            lines.append(contentsOf: blockquote(selectedText))
            lines.append("")
        } else {
            lines.append("_No active text selection._")
            lines.append("")
        }

        if !context.prefix.isEmpty || !context.suffix.isEmpty {
            lines.append("## Bounded surrounding text")
            lines.append("")
            // Page text straight from the PDF: quoted so it cannot pass for
            // the app's own structure.
            if context.activeRegion != nil {
                lines.append(contentsOf: blockquote(context.prefix + context.suffix))
            } else {
                lines.append(contentsOf: blockquote(context.prefix + (context.selectedText ?? "") + context.suffix))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A region's heading, images, caption guess and text layer, in the place
    /// a text highlight has its quote.
    ///
    /// Everything in it that comes from the PDF (page label, caption guess,
    /// text inside the box) is kept from looking like structure the app wrote:
    /// labels are flattened to one line, and longer text goes in a block quote
    /// it cannot leave. Image paths are derived from the id, not taken from
    /// the record.
    private static func regionSection(_ highlight: HighlightRecord) -> [String] {
        let page = oneLine(highlight.pageLabel)
        var lines = [
            "## Page \(page) · Region `\(highlight.id.uuidString)`",
            "",
            "A box the user drew on the page, usually around a figure or table.",
            ""
        ]
        guard let region = highlight.region else {
            lines.append("_The region's images and text are missing from its record._")
            lines.append("")
            return lines
        }
        let alt = page.filter { !"[]()".contains($0) }
        lines.append("![Boxed area, page \(alt)](\(SessionPaths.regionImagePath(for: highlight.id)))")
        lines.append("")
        lines.append(contentsOf: regionFacts(region, id: highlight.id))
        return lines
    }

    /// Image paths, caption guess and text inside the box, shared by
    /// `comments.md` and the current-context file. With the region's id the
    /// paths are the canonical ones; without it the stored paths, flattened.
    private static func regionFacts(_ region: RegionDetails, id: UUID?) -> [String] {
        let imagePath = id.map(SessionPaths.regionImagePath(for:)) ?? codeSpanSafe(region.imagePath)
        let pageImagePath = id.map(SessionPaths.regionPageImagePath(for:)) ?? codeSpanSafe(region.pageImagePath)
        var lines = [
            "- Image of the boxed area: `\(imagePath)`",
            "- Page with the box outlined: `\(pageImagePath)`",
            ""
        ]
        if let caption = region.captionGuess, !caption.isEmpty {
            lines.append("Caption (guess, nearest caption-like line on the page; verify):")
            lines.append("")
            lines.append(contentsOf: blockquote(caption))
        } else {
            lines.append("Caption (guess): none found on the page.")
        }
        lines.append("")
        if region.textInRegion.isEmpty {
            lines.append("_No text layer inside the box; only the image shows what it contains._")
        } else {
            lines.append("Text inside the box (verbatim, from the PDF's text layer):")
            lines.append("")
            lines.append(contentsOf: blockquote(region.textInRegion))
        }
        lines.append("")
        return lines
    }

    /// Text from the PDF as a block quote nothing in it can leave: split at
    /// every kind of line break, not only `\n` (CommonMark also breaks at
    /// `\r`, and other readers at U+2028, U+2029, U+0085, vertical tab and
    /// form feed), and every line prefixed. A line that starts with `#`, `>`,
    /// a fence or an HTML tag stays inside the quote.
    private static func blockquote(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                lines.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        lines.append(current)
        return lines.map { "> \($0)" }
    }

    /// One line, for a label from the PDF used inside a heading or sentence.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func codeSpanSafe(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "`", with: "'")
    }

    private static func label(for comment: CommentRecord) -> String {
        comment.kind == .quiet ? "Margin note" : "Comment"
    }
}
