import AppKit
import PDFKit
import XCTest
@testable import PaperCompanion

final class HighlightInteractionTests: XCTestCase {
    @MainActor
    func testBackspaceAndForwardDeleteReachSelectedEntry() {
        let view = HighlightClickPDFView()
        var calls = 0
        view.onDeleteKey = { calls += 1; return true }
        for code: UInt16 in [51, 117] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: code == 117 ? [.function] : [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testContextMenuActionsTargetSavedHighlight() {
        let view = HighlightClickPDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        document.insert(page, at: 0)
        view.document = document
        view.layoutDocumentView()
        let id = UUID()
        let annotation = PDFAnnotation(bounds: NSRect(x: 50, y: 50, width: 100, height: 20), forType: .highlight, withProperties: nil)
        annotation.userName = "PaperCompanion:\(id)"
        page.addAnnotation(annotation)
        let point = view.convert(NSPoint(x: 75, y: 60), from: page)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        var selected: UUID?
        var changed: String?
        var deleted: UUID?
        view.onHighlightClick = { selected = $0 }
        view.onHighlightColor = { target, color in XCTAssertEqual(target, id); changed = color }
        view.onHighlightDelete = { deleted = $0 }
        let menu = view.menu(for: event)
        XCTAssertEqual(selected, id)
        guard let green = menu?.items.first(where: { $0.title == "Green" }),
              let delete = menu?.items.last else { return XCTFail("Missing highlight menu") }
        _ = green.target?.perform(green.action, with: green)
        _ = delete.target?.perform(delete.action, with: delete)
        XCTAssertEqual(changed, "green")
        XCTAssertEqual(deleted, id)
    }
}
