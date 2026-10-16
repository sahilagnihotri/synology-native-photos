import XCTest
import PhotosCore
@testable import MySynologyPhotos

final class CoreBridgeSmokeTests: XCTestCase {
    func testCoreVersionCrossesTheFfiBoundary() {
        XCTAssertEqual(coreVersion(), "0.1.0",
                       "Rust core_version() must cross UniFFI and equal the crate version")
    }
    func testCoreVersionIsNonEmpty() {
        XCTAssertFalse(coreVersion().isEmpty)
    }
}
