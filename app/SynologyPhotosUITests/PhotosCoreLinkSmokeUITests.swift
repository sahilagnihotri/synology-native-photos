import XCTest
import PhotosCore

/// Placeholder UI test target content. `SynologyPhotosUITests` had no
/// source files yet (scaffold only), which leaves the bundle without an
/// executable and fails `xcodebuild test`. This one smoke test keeps the
/// target buildable and proves `import PhotosCore` resolves from the UI
/// test target too, by touching a real generated type rather than just
/// compiling an unused import.
final class PhotosCoreLinkSmokeUITests: XCTestCase {
    func testPhotosCoreTypesAreVisibleFromUITestTarget() {
        let connection = Connection(host: "https://192.168.1.10:5001", verifyTls: true, pinnedCertDer: nil)
        XCTAssertEqual(connection.host, "https://192.168.1.10:5001")
        XCTAssertTrue(connection.verifyTls)
    }
}
