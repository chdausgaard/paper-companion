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

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
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

/// What a highlight record anchors: highlighted text, or a box drawn over a
/// figure, table or other non-text area.
///
/// A string wrapper rather than an enum so that a kind written by a newer
/// build survives a load and save here instead of failing the whole file.
/// Compare with `==`; a `switch` needs a `default`.
public struct HighlightKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Highlighted text. The default, and what every record written before
    /// regions existed decodes as.
    public static let text = HighlightKind(rawValue: "text")
    /// A box the user drew on one page. Its rectangle is the single entry in
    /// `locations[0].lineRects`; the rest lives in `HighlightRecord.region`.
    public static let region = HighlightKind(rawValue: "region")
}

/// What the agent needs to understand a region: pictures of it and the text
/// the PDF itself carries inside it. Stored on the highlight as `region`,
/// only when `kind == .region`.
public struct RegionDetails: Codable, Equatable, Sendable {
    /// Session-relative path of the boxed area rendered from the PDF, with a
    /// small margin: `regions/<highlightID>.png`.
    public var imagePath: String
    /// Session-relative path of the whole page with the box outlined:
    /// `regions/<highlightID>-page.png`.
    public var pageImagePath: String
    /// The PDF's own text layer inside the box (axis labels, tick values,
    /// panel titles, table cells), verbatim. Empty for a raster figure.
    public var textInRegion: String
    /// The caption-like line ("Figure 3", "Table 2", …) nearest the box.
    /// Picked by a heuristic, hence the name: it can be wrong, and nil means
    /// no such line was found on the page.
    public var captionGuess: String?
    /// Character offset in the page text that the region sorts at, so it sits
    /// between the paragraphs around it in reading order. Nil on a page
    /// without a text layer.
    public var readingOffset: Int?

    public init(
        imagePath: String,
        pageImagePath: String,
        textInRegion: String = "",
        captionGuess: String? = nil,
        readingOffset: Int? = nil
    ) {
        self.imagePath = imagePath
        self.pageImagePath = pageImagePath
        self.textInRegion = textInRegion
        self.captionGuess = captionGuess
        self.readingOffset = readingOffset
    }

    // Decoded by hand so that a record missing an optional part still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        pageImagePath = try container.decode(String.self, forKey: .pageImagePath)
        textInRegion = try container.decodeIfPresent(String.self, forKey: .textInRegion) ?? ""
        captionGuess = try container.decodeIfPresent(String.self, forKey: .captionGuess)
        readingOffset = try container.decodeIfPresent(Int.self, forKey: .readingOffset)
    }
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
    /// `.text` for highlighted text, `.region` for a drawn box.
    public var kind: HighlightKind
    /// Images, text and caption guess of a region; nil for text highlights.
    public var region: RegionDetails?

    public init(
        id: UUID = UUID(),
        quote: String,
        normalizedQuote: String? = nil,
        prefix: String,
        suffix: String,
        locations: [HighlightLocation],
        color: String = "yellow",
        createdAt: Date = Date(),
        deletedAt: Date? = nil,
        kind: HighlightKind = .text,
        region: RegionDetails? = nil
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
        self.kind = kind
        self.region = region
    }

    // Decoded by hand so that sessions written before `kind` and `region`
    // existed still load, as text highlights.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        quote = try container.decode(String.self, forKey: .quote)
        normalizedQuote = try container.decodeIfPresent(String.self, forKey: .normalizedQuote) ?? quote.normalizedForSearch
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        locations = try container.decode([HighlightLocation].self, forKey: .locations)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "yellow"
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        kind = try container.decodeIfPresent(HighlightKind.self, forKey: .kind) ?? .text
        region = try container.decodeIfPresent(RegionDetails.self, forKey: .region)
    }

    public var pageIndex: Int { locations.first?.pageIndex ?? 0 }
    public var pageLabel: String { locations.first?.pageLabel ?? String(pageIndex + 1) }

    public var isRegion: Bool { kind == .region }

    /// The box of a region in page space (the space of `lineRects`, what
    /// `PDFView.convert(_:to: page)` returns), on page `pageIndex`. Nil for a
    /// text highlight.
    public var regionRect: CGRect? {
        guard isRegion else { return nil }
        return locations.first?.lineRects.first?.cgRect
    }
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
    /// Set when the active anchor is a region: where its images are and what
    /// text and caption guess it carries. Nil otherwise, and then left out of
    /// the JSON.
    public var activeRegion: RegionDetails?
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
        activeRegion: RegionDetails? = nil,
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
        self.activeRegion = activeRegion
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
        activeRegion = try container.decodeIfPresent(RegionDetails.self, forKey: .activeRegion)
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
    /// A region has no text range of its own; it sorts at the offset stored
    /// when it was drawn, next to the text around it.
    public var readingPosition: ReadingPosition {
        let first = locations.min { $0.pageIndex < $1.pageIndex }
        let offset = isRegion
            ? (region?.readingOffset ?? Int.max)
            : (first?.textRanges.map(\.location).min() ?? Int.max)
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

    /// What the entry's card shows: its comments, or the quote when the entry
    /// is a highlight with no comment, or the caption guess when it is a region
    /// with no comment. Search matches only this, so a card is never found by
    /// text the reader cannot see on it.
    public var displayedTexts: [String] {
        if !comments.isEmpty { return comments.map(\.verbatim) }
        guard let highlight else { return [] }
        if highlight.isRegion {
            return highlight.region?.captionGuess.map { [$0] } ?? []
        }
        return [highlight.quote.normalizedForSearch]
    }

    /// Entries grouped under their page, keeping the order they arrive in.
    /// Grouping is by page index, so a page appears once even if the input is
    /// not sorted.
    public static func groupedByPage(_ entries: [AnnotationEntry]) -> [AnnotationPageGroup] {
        var groups: [AnnotationPageGroup] = []
        var indexByPage: [Int: Int] = [:]
        for entry in entries {
            if let index = indexByPage[entry.pageIndex] {
                groups[index].entries.append(entry)
            } else {
                indexByPage[entry.pageIndex] = groups.count
                groups.append(AnnotationPageGroup(pageIndex: entry.pageIndex, pageLabel: entry.pageLabel, entries: [entry]))
            }
        }
        return groups
    }
}

/// The cards of one page in the annotations list, shown under a "Page N" header.
public struct AnnotationPageGroup: Identifiable, Equatable, Sendable {
    public var pageIndex: Int
    public var pageLabel: String
    public var entries: [AnnotationEntry]

    public var id: Int { pageIndex }

    public init(pageIndex: Int, pageLabel: String, entries: [AnnotationEntry]) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.entries = entries
    }
}

/// Searching the annotations list. Case- and diacritic-insensitive; every
/// whitespace-separated term must occur somewhere in what the card shows.
public enum AnnotationSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func terms(_ query: String) -> [String] {
        query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    public static func isActive(_ query: String) -> Bool {
        !terms(query).isEmpty
    }

    public static func matches(_ entry: AnnotationEntry, query: String) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        let texts = entry.displayedTexts
        return terms.allSatisfy { term in
            texts.contains { $0.range(of: term, options: options) != nil }
        }
    }

    /// The entries a query leaves visible; all of them for an empty query.
    public static func filter(_ entries: [AnnotationEntry], query: String) -> [AnnotationEntry] {
        guard isActive(query) else { return entries }
        return entries.filter { matches($0, query: query) }
    }

    /// Every occurrence of any term in `text`, sorted and with overlaps
    /// merged, for emphasizing matches in the card.
    public static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in terms(query) {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: options, range: searchStart..<text.endIndex) {
                found.append(range)
                searchStart = range.upperBound
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

extension String {
    public var normalizedForSearch: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
