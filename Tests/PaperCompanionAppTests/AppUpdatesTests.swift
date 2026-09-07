import XCTest
@testable import PaperCompanion

final class AppUpdatesTests: XCTestCase {
    @MainActor
    func testReleaseVersionsCompareNumerically() {
        XCTAssertTrue(AppUpdates.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppUpdates.isNewer("1.0", than: "0.4.0"))
        XCTAssertFalse(AppUpdates.isNewer("v0.4.0", than: "0.4"))
        XCTAssertFalse(AppUpdates.isNewer("0.3.9", than: "0.4.0"))
        XCTAssertFalse(AppUpdates.isNewer("nightly", than: "0.4.0"))
        XCTAssertFalse(AppUpdates.isNewer("1.0.0-beta", than: "0.4.0"))
    }
}
