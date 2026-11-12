import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Region anchors: a box the user draws over a figure, table or other
/// non-text area of one page, so a comment can be about it.
///
/// Everything here works in page space, the space of highlight `lineRects`
/// and of `PDFView.convert(_:to: page)`: unrotated, in PDF points, with the
/// crop box wherever the file puts it (not necessarily at the origin). Images
/// are rendered the way the page is displayed, with its rotation applied.
///
/// The images are drawn from the page's own content stream, not through
/// PDFKit, so the app's highlight annotations on the live page never end up
/// in a picture the agent reads as the paper.
public enum RegionSnapshot {
    public enum SnapshotError: Error, LocalizedError {
        case notARegion(UUID)
        case renderFailed(UUID)
        case outsideSession(URL)

        public var errorDescription: String? {
            switch self {
            case .notARegion:
                return "The record is not a region."
            case .renderFailed:
                return "Could not render the region image."
            case .outsideSession:
                return "The session's regions folder points outside the session."
            }
        }
    }

    /// A box narrower or shorter than this, after clamping to the page, is
    /// not a region but a slip of the mouse; `makeRecord` returns nil for it.
    public static let minimumSide: CGFloat = 8
    /// Points of page around the box included in the crop, so labels at the
    /// edge of a figure are not cut off.
    public static let cropMargin: CGFloat = 10
    /// Crop rendering scale, lowered for large boxes so the long side stays
    /// near `cropMaxPixels`.
    public static let cropScale: CGFloat = 3
    public static let cropMaxPixels: CGFloat = 2000
    /// Long side of the page image in pixels; enough to see where the box
    /// sits, not to read the page.
    public static let pageImageMaxPixels: CGFloat = 1200
    /// Characters of page text kept on either side of the region as its
    /// `prefix` and `suffix`, matching what a text highlight carries.
    public static let contextLength = 500

    // MARK: - Building the record

    /// A region record for `rect` (page space) on `page`, ready to append to
    /// the session's highlights. Fills the location (page index and label,
    /// crop box, rotation, the box as the single line rect), the text inside
    /// the box, the caption guess, the reading-order offset, the surrounding
    /// page text as `prefix`/`suffix`, and the session-relative image paths.
    /// It does not write the images; call `writeImages` for that.
    ///
    /// The box is clamped to the page's crop box. Returns nil when the page
    /// does not belong to a document or the clamped box is smaller than
    /// `minimumSide` on either side.
    public static func makeRecord(
        page: PDFPage,
        rect: CGRect,
        color: String = HighlightColor.yellow.rawValue,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> HighlightRecord? {
        guard let document = page.document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound,
              let box = clampedBox(rect, on: page) else { return nil }

        let lines = textLines(on: page)
        let offset = readingOffset(for: box, on: page, lines: lines)
        let context = surroundingText(on: page, at: offset)
        let crop = page.bounds(for: .cropBox)
        let location = HighlightLocation(
            pageIndex: pageIndex,
            pageLabel: page.label ?? String(pageIndex + 1),
            lineRects: [RectRecord(box)],
            textRanges: [],
            cropBox: RectRecord(crop),
            rotation: page.rotation
        )
        let details = RegionDetails(
            imagePath: SessionPaths.regionImagePath(for: id),
            pageImagePath: SessionPaths.regionPageImagePath(for: id),
            textInRegion: text(in: box, on: page),
            captionGuess: captionGuess(for: box, on: page, lines: lines),
            readingOffset: offset
        )
        return HighlightRecord(
            id: id,
            quote: "",
            prefix: context.prefix,
            suffix: context.suffix,
            locations: [location],
            color: color,
            createdAt: createdAt,
            kind: .region,
            region: details
        )
    }

    /// `rect` standardized and clipped to the crop box, or nil when what is
    /// left is smaller than `minimumSide`.
    public static func clampedBox(_ rect: CGRect, on page: PDFPage) -> CGRect? {
        let box = rect.standardized.intersection(page.bounds(for: .cropBox))
        guard !box.isNull, box.width >= minimumSide, box.height >= minimumSide else { return nil }
        return box
    }

    // MARK: - Images

    /// Renders both images of a region and writes them to
    /// `regions/<id>.png` and `regions/<id>-page.png`, creating `regions/` if
    /// needed. The names come from the record's id, never from the paths
    /// stored in it, so a hand-edited record cannot send a write elsewhere.
    /// An image that already exists is left alone, even one that appears
    /// while this one renders: the files are written once, when the region is
    /// drawn, and kept after a delete so an undo finds them again.
    ///
    /// Throws when `regions/` is a symlink out of the session folder.
    @discardableResult
    public static func writeImages(
        for highlight: HighlightRecord,
        page: PDFPage,
        paths: SessionPaths
    ) throws -> (image: URL, pageImage: URL) {
        try writeImages(for: highlight, page: page, paths: paths, beforeCommit: {})
    }

    /// `beforeCommit` runs after each image is rendered and before it is put
    /// in place, so a test can create the file in between.
    static func writeImages(
        for highlight: HighlightRecord,
        page: PDFPage,
        paths: SessionPaths,
        beforeCommit: () -> Void
    ) throws -> (image: URL, pageImage: URL) {
        guard highlight.isRegion, let box = highlight.regionRect else {
            throw SnapshotError.notARegion(highlight.id)
        }
        let imageURL = paths.root.appendingPathComponent(SessionPaths.regionImagePath(for: highlight.id))
        let pageImageURL = paths.root.appendingPathComponent(SessionPaths.regionPageImagePath(for: highlight.id))
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.regions, withIntermediateDirectories: true)
        guard paths.regionsRealPath != nil else { throw SnapshotError.outsideSession(paths.regions) }

        for (url, render) in [
            (imageURL, { cropPNG(of: box, on: page) }),
            (pageImageURL, { pagePNG(outlining: box, on: page) })
        ] as [(URL, () -> Data?)] {
            // Saves the render when the file is plainly there already; the
            // commit below is what actually guarantees no overwrite.
            if (try? fileManager.attributesOfItem(atPath: url.path)) != nil { continue }
            guard let data = render() else { throw SnapshotError.renderFailed(highlight.id) }
            beforeCommit()
            try commitIfAbsent(data, to: url)
        }
        return (imageURL, pageImageURL)
    }

    /// Puts `data` at `destination` only if nothing is there, atomically: the
    /// bytes go to a temporary file in the same folder, which is then
    /// hard-linked into place. `link` fails rather than replace an existing
    /// name (a file, a folder or a dangling symlink, which it does not
    /// follow), so a reader never sees a partial file and a file that
    /// appeared in the meantime is kept. Returns false when something was
    /// already there.
    @discardableResult
    static func commitIfAbsent(_ data: Data, to destination: URL) throws -> Bool {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { _ = unlink(temporary.path) }
        if link(temporary.path, destination.path) == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// PNG of the box (page space) plus `cropMargin`, upright as displayed,
    /// at `cropScale` with the long side capped near `cropMaxPixels`.
    public static func cropPNG(of box: CGRect, on page: PDFPage) -> Data? {
        cropImage(of: box, on: page).flatMap(pngData)
    }

    /// PNG of the whole page, upright as displayed, about
    /// `pageImageMaxPixels` on the long side, with the box outlined in red.
    public static func pagePNG(outlining box: CGRect, on page: PDFPage) -> Data? {
        pageImage(outlining: box, on: page).flatMap(pngData)
    }

    public static func cropImage(of box: CGRect, on page: PDFPage) -> CGImage? {
        let transform = displayTransform(for: page)
        let size = displaySize(of: page)
        let displayBox = box.applying(transform).standardized
        let area = displayBox
            .insetBy(dx: -cropMargin, dy: -cropMargin)
            .intersection(CGRect(origin: .zero, size: size))
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let scale = min(cropScale, cropMaxPixels / max(area.width, area.height))
        return render(page: page, area: area, scale: scale, outline: nil)
    }

    public static func pageImage(outlining box: CGRect, on page: PDFPage) -> CGImage? {
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, pageImageMaxPixels / max(size.width, size.height))
        let displayBox = box.applying(displayTransform(for: page)).standardized
        return render(page: page, area: CGRect(origin: .zero, size: size), scale: scale, outline: displayBox)
    }

    /// Maps page space to the page as displayed: crop box origin moved to
    /// zero, then the page's clockwise rotation applied, y up. A box in
    /// `lineRects` passed through this lands where the reader sees it.
    public static func displayTransform(for page: PDFPage) -> CGAffineTransform {
        let crop = page.bounds(for: .cropBox)
        let width = crop.width
        let height = crop.height
        let toOrigin = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        let rotate: CGAffineTransform
        switch normalizedRotation(page.rotation) {
        case 90:
            // Clockwise quarter turn: the left edge becomes the top.
            rotate = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 180:
            rotate = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 270:
            rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default:
            rotate = .identity
        }
        return toOrigin.concatenating(rotate)
    }

    /// Size of the page as displayed: the crop box, width and height swapped
    /// for a quarter-turn rotation.
    public static func displaySize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        switch normalizedRotation(page.rotation) {
        case 90, 270: return CGSize(width: crop.height, height: crop.width)
        default: return crop.size
        }
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }

    /// Draws `area` (display space) of the page into a white bitmap at
    /// `scale`, optionally stroking `outline` (display space) on top.
    private static func render(page: PDFPage, area: CGRect, scale: CGFloat, outline: CGRect?) -> CGImage? {
        let pixelWidth = max(1, Int((area.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((area.height * scale).rounded(.up)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)

        context.saveGState()
        context.concatenate(displayTransform(for: page))
        context.clip(to: page.bounds(for: .cropBox))
        if let pageRef = page.pageRef {
            // The raw content stream, in page space, without annotations.
            context.drawPDFPage(pageRef)
        } else {
            // A page with no backing PDF (built in memory). PDFKit draws it
            // already transformed for the box, so undo that to stay in page
            // space.
            context.concatenate(page.transform(for: .mediaBox).inverted())
            page.draw(with: .mediaBox, to: context)
        }
        context.restoreGState()

        if let outline {
            let lineWidth = 3 / scale
            context.setStrokeColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            context.setLineWidth(lineWidth)
            // Just outside the box, so the outline does not cover what the
            // user boxed; but never past the edge of the image, or a box that
            // reaches the page edge would lose that side of its outline.
            let outside = outline.insetBy(dx: -lineWidth / 2 - 1, dy: -lineWidth / 2 - 1)
            let stroked = outside.intersection(area.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            context.stroke(stroked.isNull ? outside : stroked)
        }
        return context.makeImage()
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Text

    /// One line of the page's text layer, with where it sits.
    struct TextLine {
        var text: String
        /// Page space.
        var bounds: CGRect
        /// Location in `page.string`.
        var range: NSRange
    }

    /// The text layer inside the box, verbatim, with line breaks kept and the
    /// ends trimmed. Empty when the area has no text (a raster figure).
    public static func text(in box: CGRect, on page: PDFPage) -> String {
        guard let selection = page.selection(for: box), let string = selection.string else { return "" }
        return string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textLines(on page: PDFPage) -> [TextLine] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let string = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty,
                  line.numberOfTextRanges(on: page) > 0 else { return nil }
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { return nil }
            return TextLine(text: string, bounds: bounds, range: line.range(at: 0, on: page))
        }
    }

    // MARK: - Caption guess

    /// The caption-like line nearest the box: one that starts like "Figure 3",
    /// "Fig. 3", "Table 2", "Figur", "Tabel", "Panel A" or "Exhibit 1".
    /// Nil when the page has none.
    ///
    /// A heuristic, and recorded as `captionGuess` for that reason. It picks
    /// the nearest such line, which can be the caption of a neighbouring
    /// figure; and a line of body text that happens to begin "Table 2 shows"
    /// is only penalized, not excluded, so on a page with no real caption it
    /// can win.
    public static func captionGuess(for box: CGRect, on page: PDFPage) -> String? {
        captionGuess(for: box, on: page, lines: textLines(on: page))
    }

    static func captionGuess(for box: CGRect, on page: PDFPage, lines: [TextLine]) -> String? {
        let transform = displayTransform(for: page)
        let displayBox = box.applying(transform).standardized
        var best: (score: CGFloat, index: Int)?
        for (index, line) in lines.enumerated() {
            guard let kind = captionKind(of: line.text) else { continue }
            let distance = rectDistance(line.bounds.applying(transform).standardized, displayBox)
            // Prose that merely starts with a reference ("Table 2 reports …")
            // loses to a real caption anywhere nearby.
            let score = distance + (kind == .prose ? 400 : 0)
            if best == nil || score < best!.score { best = (score, index) }
        }
        guard let best else { return nil }
        var caption = lines[best.index].text
        // A label alone on its line ("Figure 3") takes its title from the next.
        if captionKind(of: caption) == .labelOnly, best.index + 1 < lines.count {
            caption += " " + lines[best.index + 1].text
        }
        caption = caption.normalizedForSearch
        return caption.count > 300 ? String(caption.prefix(300)) + "…" : caption
    }

    enum CaptionKind: Equatable {
        /// "Figure 3: Effect of …", "TABLE II. Estimates", "Table 2 Effects"
        case caption
        /// "Figure 3" or "Figure 3." with nothing after it.
        case labelOnly
        /// "Table 2 reports …", "Figure 3, which …": a reference in running text.
        case prose
    }

    private static let captionLabel: NSRegularExpression = {
        // Label word, then a number ("3", "3a", "2.1"), or after a space an
        // appendix number ("A1"), a roman numeral ("II") or a panel letter
        // ("A"). The space keeps "Figures 3" from reading as "Figure s".
        let pattern = #"^(?:figure|figur|fig\.?|table|tabel|panel|exhibit)(?:\s*[0-9]+[a-z]?(?:\.[0-9]+)?\b|\s+(?:[A-Z][0-9]+(?:\.[0-9]+)?|[IVXLC]+|[A-Z])\b)"#
        // Safe to force: the pattern is a constant, and a bad one fails every test.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func captionKind(of line: String) -> CaptionKind? {
        let text = line.trimmingCharacters(in: .whitespaces)
        // Captions start with a capital: "Figure", "FIGURE", "Fig."; a lower
        // case "table 2" is running text.
        guard let first = text.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return nil }
        let nsText = text as NSString
        guard let match = captionLabel.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        let rest = nsText.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
        guard let next = rest.unicodeScalars.first else { return .labelOnly }
        if ".:|—–-".unicodeScalars.contains(next) {
            let afterPunctuation = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return afterPunctuation.isEmpty ? .labelOnly : .caption
        }
        if CharacterSet.uppercaseLetters.contains(next) || CharacterSet.decimalDigits.contains(next) {
            return .caption
        }
        return .prose
    }

    /// Shortest distance between two rectangles; zero when they touch or
    /// overlap.
    static func rectDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Reading order

    /// Offset in the page text where the region belongs in reading order: by
    /// the text line nearest the box's top-left corner as displayed. A line
    /// that sits above the box puts the region after it; one beside or below
    /// puts it before. Lines mostly inside the box are skipped, because a
    /// figure's own labels often sit out of order in the text layer. Nil on a
    /// page without text.
    public static func readingOffset(for box: CGRect, on page: PDFPage) -> Int? {
        readingOffset(for: box, on: page, lines: textLines(on: page))
    }

    static func readingOffset(for box: CGRect, on page: PDFPage, lines: [TextLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let transform = displayTransform(for: page)
        let displayBox = box.applying(transform).standardized
        let corner = CGPoint(x: displayBox.minX, y: displayBox.maxY)

        let outside = lines.filter { line in
            let inside = line.bounds.intersection(box)
            let area = line.bounds.width * line.bounds.height
            guard !inside.isNull, area > 0 else { return true }
            return inside.width * inside.height < area / 2
        }
        // A box over the whole text of the page: fall back to its first line.
        guard !outside.isEmpty else { return lines.map(\.range.location).min() }

        var best: (distance: CGFloat, line: TextLine)?
        for line in outside {
            let distance = rectDistance(
                line.bounds.applying(transform).standardized,
                CGRect(origin: corner, size: .zero)
            )
            if best == nil || distance < best!.distance { best = (distance, line) }
        }
        guard let best else { return nil }
        let lineBox = best.line.bounds.applying(transform).standardized
        return lineBox.midY >= displayBox.maxY
            ? best.line.range.location + best.line.range.length
            : best.line.range.location
    }

    /// Up to `contextLength` characters of page text on either side of
    /// `offset`, like the `prefix` and `suffix` of a text highlight.
    static func surroundingText(on page: PDFPage, at offset: Int?) -> (prefix: String, suffix: String) {
        guard let offset, let string = page.string else { return ("", "") }
        let text = string as NSString
        let location = min(max(0, offset), text.length)
        let prefixStart = max(0, location - contextLength)
        let suffixLength = min(contextLength, text.length - location)
        return (
            text.substring(with: NSRange(location: prefixStart, length: location - prefixStart)),
            text.substring(with: NSRange(location: location, length: suffixLength))
        )
    }
}
