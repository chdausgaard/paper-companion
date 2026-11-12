import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import PaperCompanion
@testable import PaperCompanionCore

/// Renders the real PDF reader (`PDFReaderView` and its
/// `HighlightClickPDFView`) offscreen with a PDF built here and highlights
/// made the way the user makes them, and writes PNGs to the folder named by
/// `PAPER_COMPANION_SNAPSHOT_DIR`. Skipped when the variable is not set.
/// Hover comes from real mouse-moved events, so the PNGs show what the
/// events produce, not a forced look.
///
///     PAPER_COMPANION_SNAPSHOT_DIR=/tmp/snapshots swift test --filter Snapshot
final class PDFSnapshotTests: XCTestCase {
    static let pages = [
        """
        Effects of early rollout on turnout

        Treated municipalities saw turnout rise relative to the synthetic control, and the gap opened in the first election after the reform.

        We estimate the effect with two-way fixed effects and report event-study coefficients in the appendix.

        Turnout among first-time voters rose by 4.2 percentage points in treated municipalities, against 1.1 points elsewhere.
        """,
        """
        The design exploits the staggered rollout across regions between 2009 and 2015.

        Effects are larger where the rollout came early in the electoral cycle, which the next section examines.
        """,
    ]

    private enum Look: String {
        case normal = "01-pdf-normal"
        case hovered = "02-pdf-hovered"
        case selected = "03-pdf-selected"
        case selectedHovered = "04-pdf-selected-hovered"
        case pageHoverLightsCard = "05-window-page-hover-lights-card"
        case cardHoverLightsPage = "06-window-card-hover-lights-page"
    }

    @MainActor
    private func render(_ look: Look) throws {
        let directory = try SnapshotOutput.directory()
        for dark in [false, true] {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            let state = AppState()
            state.autoHighlightEnabled = false
            state.document = TestPDF.make(pages: Self.pages, size: NSSize(width: 500, height: 330))
            let harness = try ReaderHarness(test: self, state: state, appearance: appearance)
            defer { harness.close(self) }
            let rise = try harness.highlight("turnout rise relative to the synthetic control", test: self)
            let fixed = try harness.highlight("two-way fixed effects", color: "blue", test: self)
            let firstTime = try harness.highlight("4.2 percentage points", color: "green", test: self)
            let staggered = try harness.highlight("staggered rollout", color: "pink", test: self)
            state.comments = [
                CommentRecord(highlightID: fixed, pageIndex: 0, pageLabel: "1",
                              verbatim: "TWFE with staggered timing: are the effect sizes biased by forbidden comparisons?"),
            ]
            _ = (rise, firstTime, staggered)
            spin(0.5)
            harness.window.makeFirstResponder(harness.pdfView)

            switch look {
            case .normal:
                break
            case .hovered, .pageHoverLightsCard:
                moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: fixed), in: harness.window)
            case .selected:
                state.highlightClicked(fixed)
            case .selectedHovered:
                state.highlightClicked(fixed)
                spin(0.2)
                moveMouse(toWindowPoint: try harness.windowPoint(ofHighlight: fixed), in: harness.window)
            case .cardHoverLightsPage:
                // The pointer rests on the card of the pink highlight, the
                // last card in the list.
                spin(0.3)
                let card = try XCTUnwrap(harness.cardTextFrames(self).last)
                let point = NSPoint(x: card.midX, y: card.midY)
                let tracker = try harness.hoverTracker(at: point, self)
                pointer(.mouseEntered, atWindowPoint: point, trackedBy: tracker)
                pointer(.mouseMoved, atWindowPoint: point, trackedBy: tracker)
            }
            spin(0.5)
            harness.host.layoutSubtreeIfNeeded()
            if look == .cardHoverLightsPage {
                XCTAssertEqual(state.annotationHover.cardHoveredID, staggered, "the pointer on the pink card")
            }

            let wholeWindow = look == .pageHoverLightsCard || look == .cardHoverLightsPage
            let rect = wholeWindow ? harness.host.bounds
                : NSRect(x: 0, y: 0, width: ReaderHarness.pdfWidth, height: harness.host.bounds.height)
            let url = directory.appendingPathComponent("\(look.rawValue)-\(dark ? "dark" : "light").png")
            let image = try SnapshotOutput.readerBitmap(of: harness.host, pdfView: harness.pdfView, appearance: appearance, rect: rect)
            let bytes = try SnapshotOutput.writePNG(image, to: url)
            try checkDesk(in: image, harness: harness, appearance: appearance, name: url.lastPathComponent)
            XCTAssertGreaterThan(bytes, 10_000, "\(url.lastPathComponent) looks blank")
        }
    }

    /// The pages sit on the system's under-page "desk". PDFView's scroll view
    /// draws a semantic background color as the matching material (here
    /// `.underPageBackground`; `.windowBackground` before), so the check is
    /// on the material and on the rendered contrast, not on the static color
    /// value, which the material does not use.
    @MainActor
    private func checkDesk(in image: NSBitmapImageRep, harness: ReaderHarness, appearance: NSAppearance, name: String) throws {
        let materials = descendants(of: harness.pdfView, as: NSVisualEffectView.self).map(\.material)
        XCTAssertEqual(materials, [.underPageBackground], "\(name): the desk material")
        let page = try XCTUnwrap(harness.pdfView.document?.page(at: 0))
        let box = page.bounds(for: harness.pdfView.displayBox)
        func brightness(atPagePoint point: NSPoint) throws -> CGFloat {
            let inHost = harness.host.convert(harness.pdfView.convert(point, from: page), from: harness.pdfView)
            let scale = CGFloat(image.pixelsWide) / image.size.width
            let row = harness.host.isFlipped ? inHost.y : harness.host.bounds.height - inHost.y
            let color = try XCTUnwrap(image.colorAt(x: Int(inHost.x * scale), y: Int(row * scale))?.usingColorSpace(.sRGB))
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        // Above the first page, clear of its shadow, which falls downward.
        let desk = try brightness(atPagePoint: NSPoint(x: box.midX, y: box.maxY + 6))
        let paper = try brightness(atPagePoint: NSPoint(x: box.maxX - 12, y: box.minY + 12))
        XCTAssertGreaterThan(paper - desk, 0.04, "\(name): the page (\(paper)) stands off the desk (\(desk))")
    }

    /// The four looks of a highlight, one row each, for every color: the same
    /// highlight rendered in each real state (hover by a real mouse-moved
    /// event, selection as a click makes it), cropped to its line. The rows
    /// must read as three clear steps above rest, with black text still easy
    /// to read on the strongest. Prints the fill each step produced.
    @MainActor
    func testSnapshotHighlightStates() throws {
        let directory = try SnapshotOutput.directory()
        let states = ["Normal", "Hovered", "Selected", "Selected + hovered"]
        let colors = HighlightColor.allCases.map(\.rawValue)
        let cropSize = NSSize(width: 300, height: 34)
        let labelWidth: CGFloat = 150
        for dark in [false, true] {
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            var crops: [[NSBitmapImageRep]] = []
            for color in colors {
                var column: [NSBitmapImageRep] = []
                for index in states.indices {
                    let state = AppState()
                    state.autoHighlightEnabled = false
                    state.document = TestPDF.make(pages: Self.pages, size: NSSize(width: 500, height: 330))
                    let harness = try ReaderHarness(test: self, state: state, appearance: appearance)
                    defer { harness.close(self) }
                    let id = try harness.highlight("two-way fixed effects", color: color, test: self)
                    spin(0.4)
                    harness.window.makeFirstResponder(harness.pdfView)
                    if index >= 2 { state.highlightClicked(id); spin(0.2) }
                    let onIt = try harness.windowPoint(ofHighlight: id)
                    moveMouse(toWindowPoint: index % 2 == 1 ? onIt : try harness.windowPoint(ofText: "Effects of early"), in: harness.window)
                    spin(0.3)
                    XCTAssertEqual(harness.pdfView.hoveredAnnotationID == id, index % 2 == 1, "\(color) \(states[index])")
                    XCTAssertEqual(state.selectedHighlightID == id, index >= 2, "\(color) \(states[index])")

                    let annotation = try XCTUnwrap(harness.annotations()[id]?.first)
                    let page = try XCTUnwrap(annotation.page)
                    let line = harness.host.convert(harness.pdfView.convert(annotation.bounds, from: page), from: harness.pdfView)
                    let rect = NSRect(x: line.minX - 60, y: line.midY - cropSize.height / 2, width: cropSize.width, height: cropSize.height)
                    let crop = try SnapshotOutput.readerBitmap(of: harness.host, pdfView: harness.pdfView, appearance: appearance, rect: rect)
                    column.append(crop)
                    // The fill: the lightest pixel along the top of the line,
                    // above the glyphs.
                    let scale = CGFloat(crop.pixelsWide) / crop.size.width
                    let topRow = Int((cropSize.height / 2 - line.height / 2 + 1.5) * scale)
                    let fill = stride(from: Int(62 * scale), to: Int((60 + line.width - 2) * scale), by: 2)
                        .compactMap { crop.colorAt(x: $0, y: topRow)?.usingColorSpace(.sRGB) }
                        .max { $0.brightnessComponent < $1.brightnessComponent }
                    if let fill {
                        let rgb = [fill.redComponent, fill.greenComponent, fill.blueComponent].map { Int(($0 * 255).rounded()) }
                        print("STATE \(dark ? "dark" : "light") \(color) \(states[index]): rgb \(rgb), contrast with black \(String(format: "%.1f", Self.contrastWithBlack(fill))):1")
                    }
                }
                crops.append(column)
            }

            // One sheet: a label column, then one column per color.
            let size = NSSize(width: labelWidth + CGFloat(colors.count) * (cropSize.width + 8), height: 30 + CGFloat(states.count) * (cropSize.height + 6))
            let sheet = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            sheet.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: size).fill()
                let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
                for (column, color) in colors.enumerated() {
                    (color.capitalized as NSString).draw(at: NSPoint(x: labelWidth + CGFloat(column) * (cropSize.width + 8) + 4, y: size.height - 22), withAttributes: label)
                }
                for (row, name) in states.enumerated() {
                    let y = size.height - 30 - CGFloat(row + 1) * (cropSize.height + 6)
                    (name as NSString).draw(at: NSPoint(x: 12, y: y + 10), withAttributes: label)
                    for column in colors.indices {
                        crops[column][row].draw(in: NSRect(x: labelWidth + CGFloat(column) * (cropSize.width + 8), y: y, width: cropSize.width, height: cropSize.height))
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let url = directory.appendingPathComponent("07-highlight-states-\(dark ? "dark" : "light").png")
            XCTAssertGreaterThan(try SnapshotOutput.writePNG(sheet, to: url), 10_000)
        }
    }

    /// WCAG contrast ratio of black text on `color`.
    private static func contrastWithBlack(_ color: NSColor) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        return (luminance + 0.05) / 0.05
    }

    @MainActor func testSnapshotPDFNormal() throws { try render(.normal) }
    @MainActor func testSnapshotPDFHovered() throws { try render(.hovered) }
    @MainActor func testSnapshotPDFSelected() throws { try render(.selected) }
    @MainActor func testSnapshotPDFSelectedHovered() throws { try render(.selectedHovered) }
    @MainActor func testSnapshotPageHoverLightsCard() throws { try render(.pageHoverLightsCard) }
    @MainActor func testSnapshotCardHoverLightsPage() throws { try render(.cardHoverLightsPage) }
}
