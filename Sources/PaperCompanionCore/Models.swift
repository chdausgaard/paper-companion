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

    public var id: UUID
    public var highlightID: UUID?
    public var pageIndex: Int?
    public var pageLabel: String?
    public var verbatim: String
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
        self.captureMethod = captureMethod
        self.tags = tags
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.pdfToolkitPath = pdfToolkitPath
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
        self.updatedAt = updatedAt
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

extension String {
    public var normalizedForSearch: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
