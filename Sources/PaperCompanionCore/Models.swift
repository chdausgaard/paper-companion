import Foundation

public struct RectRecord: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TextRangeRecord: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct HighlightLocation: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var pageLabel: String
    public var lineRects: [RectRecord]
    public var textRanges: [TextRangeRecord]
    public var cropBox: RectRecord?
    public var rotation: Int

    public init(
        pageIndex: Int,
        pageLabel: String,
        lineRects: [RectRecord],
        textRanges: [TextRangeRecord],
        cropBox: RectRecord? = nil,
        rotation: Int = 0
    ) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.lineRects = lineRects
        self.textRanges = textRanges
        self.cropBox = cropBox
        self.rotation = rotation
    }
}

public struct SelectionSnapshot: Codable, Equatable, Sendable {
    public var selectedText: String
    public var prefix: String
    public var suffix: String
    public var locations: [HighlightLocation]
    public var capturedAt: Date

    public init(
        selectedText: String,
        prefix: String,
        suffix: String,
        locations: [HighlightLocation],
        capturedAt: Date = Date()
    ) {
        self.selectedText = selectedText
        self.prefix = prefix
        self.suffix = suffix
        self.locations = locations
        self.capturedAt = capturedAt
    }

    public var primaryPageIndex: Int? { locations.first?.pageIndex }
    public var primaryPageLabel: String? { locations.first?.pageLabel }
}

public struct HighlightRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var quote: String
    public var normalizedQuote: String
    public var prefix: String
    public var suffix: String
    public var locations: [HighlightLocation]
    public var color: String
    public var createdAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        quote: String,
        normalizedQuote: String? = nil,
        prefix: String,
        suffix: String,
        locations: [HighlightLocation],
        color: String = "yellow",
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.quote = quote
        self.normalizedQuote = normalizedQuote ?? quote.normalizedForSearch
        self.prefix = prefix
        self.suffix = suffix
        self.locations = locations
        self.color = color
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    public var pageIndex: Int { locations.first?.pageIndex ?? 0 }
    public var pageLabel: String { locations.first?.pageLabel ?? String(pageIndex + 1) }
}

public struct CommentRecord: Codable, Equatable, Identifiable, Sendable {
    public enum CaptureMethod: String, Codable, Sendable {
        case typed
        case voiceTranscript
        case imported
    }

    /// How much attention a comment asks of the agent.
    ///
    /// `discuss` is the normal case: the agent tests the point and responds.
    /// `quiet` is a margin note — recorded verbatim, folded into the synthesis
    /// if it turns out to matter, but never answered in the moment. It exists so
    /// that small reactions ("nice explanation") cost nothing to write down.
    public enum Kind: String, Codable, Sendable {
        case discuss
        case quiet
    }

    public var id: UUID
    public var highlightID: UUID?
    public var pageIndex: Int?
    public var pageLabel: String?
    public var verbatim: String
    public var kind: Kind
    public var captureMethod: CaptureMethod
    public var tags: [String]
    public var status: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        highlightID: UUID? = nil,
        pageIndex: Int? = nil,
        pageLabel: String? = nil,
        verbatim: String,
        kind: Kind = .discuss,
        captureMethod: CaptureMethod = .typed,
        tags: [String] = [],
        status: String = "captured",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.highlightID = highlightID
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.verbatim = verbatim
        self.kind = kind
        self.captureMethod = captureMethod
        self.tags = tags
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    // Decoded by hand so that sessions written before `kind` existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        highlightID = try container.decodeIfPresent(UUID.self, forKey: .highlightID)
        pageIndex = try container.decodeIfPresent(Int.self, forKey: .pageIndex)
        pageLabel = try container.decodeIfPresent(String.self, forKey: .pageLabel)
        verbatim = try container.decode(String.self, forKey: .verbatim)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .discuss
        captureMethod = try container.decodeIfPresent(CaptureMethod.self, forKey: .captureMethod) ?? .typed
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "captured"
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// Whether the agent reads the paper ahead of the user or discovers it with him.
public enum ReadingMode: String, Codable, Sendable, CaseIterable {
    /// The agent pre-reads the paper and fills the map before comments arrive.
    case preread
    /// The agent reads only what the user has reached: highlight snippets and
    /// the pages up to the furthest one opened. Nothing ahead.
    case together

    public var title: String {
        switch self {
        case .preread: return "Agent pre-reads"
        case .together: return "Discover together"
        }
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var sourcePDFPath: String
    public var sourcePDFFingerprint: String
    public var pageCount: Int
    public var lastPageIndex: Int
    /// Highest page index the user has opened in this session. In `together`
    /// mode the agent must not read past it.
    public var furthestPageIndex: Int
    public var readingMode: ReadingMode
    public var createdAt: Date
    public var updatedAt: Date
    public var pdfToolkitPath: String?

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        title: String,
        sourcePDFPath: String,
        sourcePDFFingerprint: String,
        pageCount: Int,
        lastPageIndex: Int = 0,
        furthestPageIndex: Int = 0,
        readingMode: ReadingMode = .preread,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        pdfToolkitPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.sourcePDFPath = sourcePDFPath
        self.sourcePDFFingerprint = sourcePDFFingerprint
        self.pageCount = pageCount
        self.lastPageIndex = lastPageIndex
        self.furthestPageIndex = max(furthestPageIndex, lastPageIndex)
        self.readingMode = readingMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.pdfToolkitPath = pdfToolkitPath
    }

    // Decoded by hand so sessions written before `readingMode` and
    // `furthestPageIndex` existed still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sourcePDFPath = try container.decode(String.self, forKey: .sourcePDFPath)
        sourcePDFFingerprint = try container.decode(String.self, forKey: .sourcePDFFingerprint)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastPageIndex = try container.decodeIfPresent(Int.self, forKey: .lastPageIndex) ?? 0
        furthestPageIndex = max(
            try container.decodeIfPresent(Int.self, forKey: .furthestPageIndex) ?? 0,
            lastPageIndex
        )
        readingMode = try container.decodeIfPresent(ReadingMode.self, forKey: .readingMode) ?? .preread
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        pdfToolkitPath = try container.decodeIfPresent(String.self, forKey: .pdfToolkitPath)
    }
}

public struct CurrentContext: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionID: UUID
    public var sourcePDFPath: String
    public var sourcePDFFingerprint: String
    public var pageIndex: Int
    public var pageLabel: String
    public var selectedText: String?
    public var prefix: String
    public var suffix: String
    public var activeHighlightID: UUID?
    public var textStatus: String
    public var readingMode: ReadingMode
    public var furthestPageIndex: Int
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        sourcePDFPath: String,
        sourcePDFFingerprint: String,
        pageIndex: Int,
        pageLabel: String,
        selectedText: String?,
        prefix: String,
        suffix: String,
        activeHighlightID: UUID?,
        textStatus: String,
        readingMode: ReadingMode = .preread,
        furthestPageIndex: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.sourcePDFPath = sourcePDFPath
        self.sourcePDFFingerprint = sourcePDFFingerprint
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.selectedText = selectedText
        self.prefix = prefix
        self.suffix = suffix
        self.activeHighlightID = activeHighlightID
        self.textStatus = textStatus
        self.readingMode = readingMode
        self.furthestPageIndex = furthestPageIndex
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        sourcePDFPath = try container.decode(String.self, forKey: .sourcePDFPath)
        sourcePDFFingerprint = try container.decode(String.self, forKey: .sourcePDFFingerprint)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        pageLabel = try container.decode(String.self, forKey: .pageLabel)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        activeHighlightID = try container.decodeIfPresent(UUID.self, forKey: .activeHighlightID)
        textStatus = try container.decode(String.self, forKey: .textStatus)
        readingMode = try container.decodeIfPresent(ReadingMode.self, forKey: .readingMode) ?? .preread
        furthestPageIndex = try container.decodeIfPresent(Int.self, forKey: .furthestPageIndex) ?? pageIndex
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public struct SessionEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var actor: String
    public var origin: String
    public var kind: String
    public var recordID: UUID?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        actor: String,
        origin: String,
        kind: String,
        recordID: UUID? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.actor = actor
        self.origin = origin
        self.kind = kind
        self.recordID = recordID
        self.timestamp = timestamp
    }
}

/// Where something sits in the paper, for sorting in reading order rather
/// than creation order.
///
/// Within a page the key is the character offset PDFKit assigns to the text,
/// which follows its reading order and so keeps two-column layouts in sequence
/// better than geometry would. Anchors without text (page-only comments) sort
/// to the top of their page.
public struct ReadingPosition: Comparable, Equatable, Sendable {
    public var pageIndex: Int
    public var offset: Int
    public var createdAt: Date

    public init(pageIndex: Int, offset: Int, createdAt: Date) {
        self.pageIndex = pageIndex
        self.offset = offset
        self.createdAt = createdAt
    }

    public static func < (lhs: ReadingPosition, rhs: ReadingPosition) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
        if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
        return lhs.createdAt < rhs.createdAt
    }
}

extension HighlightRecord {
    public var readingPosition: ReadingPosition {
        let first = locations.min { $0.pageIndex < $1.pageIndex }
        let offset = first?.textRanges.map(\.location).min() ?? Int.max
        return ReadingPosition(
            pageIndex: first?.pageIndex ?? 0,
            offset: offset,
            createdAt: createdAt
        )
    }
}

/// One row of the annotations list: a highlight with the comments linked to
/// it, or a comment with no active highlight (page-only, or orphaned by a
/// removed highlight).
public struct AnnotationEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var highlight: HighlightRecord?
    public var comments: [CommentRecord]
    public var position: ReadingPosition

    public var pageIndex: Int { position.pageIndex }
    public var pageLabel: String {
        highlight?.pageLabel ?? comments.first?.pageLabel ?? String(position.pageIndex + 1)
    }

    /// Active highlights and comments merged and sorted into reading order.
    public static func build(highlights: [HighlightRecord], comments: [CommentRecord]) -> [AnnotationEntry] {
        let active = highlights.filter { $0.deletedAt == nil }
        let live = comments.filter { $0.status != "deleted" }
        let activeIDs = Set(active.map(\.id))

        var entries = active.map { highlight in
            AnnotationEntry(
                id: highlight.id,
                highlight: highlight,
                comments: live
                    .filter { $0.highlightID == highlight.id }
                    .sorted { $0.createdAt < $1.createdAt },
                position: highlight.readingPosition
            )
        }
        for comment in live where comment.highlightID.map({ !activeIDs.contains($0) }) ?? true {
            entries.append(AnnotationEntry(
                id: comment.id,
                highlight: nil,
                comments: [comment],
                position: ReadingPosition(
                    pageIndex: comment.pageIndex ?? 0,
                    offset: -1,
                    createdAt: comment.createdAt
                )
            ))
        }
        return entries.sorted { $0.position < $1.position }
    }
}

extension String {
    public var normalizedForSearch: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
