import Foundation

public enum MarkdownExporter {
    public static func renderComments(
        title: String,
        highlights: [HighlightRecord],
        comments: [CommentRecord]
    ) -> String {
        var lines = [
            "# Reading comments: \(escapeHeading(title))",
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
            lines.append("## Page \(highlight.pageLabel) · Highlight `\(highlight.id.uuidString)`")
            lines.append("")
            lines.append(contentsOf: blockquote(highlight.quote))
            lines.append("")

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
                let page = comment.pageLabel.map { " · Page \($0)" } ?? ""
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
            "- Page: \(context.pageLabel) (index \(context.pageIndex))",
            "- PDF: `\(context.sourcePDFPath)`",
            "- Source fingerprint: `\(context.sourcePDFFingerprint)`",
            "- Text status: \(context.textStatus)",
            "- Updated: \(ISO8601DateFormatter().string(from: context.updatedAt))"
        ]
        if let highlightID = context.activeHighlightID {
            lines.append("- Active highlight: `\(highlightID.uuidString)`")
        }
        lines.append("")

        if let selectedText = context.selectedText, !selectedText.isEmpty {
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
            lines.append(context.prefix + (context.selectedText ?? "") + context.suffix)
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func label(for comment: CommentRecord) -> String {
        comment.kind == .quiet ? "Margin note" : "Comment"
    }

    private static func blockquote(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
    }

    private static func escapeHeading(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
