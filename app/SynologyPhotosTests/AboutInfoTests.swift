import XCTest
@testable import SynologyPhotos

final class AboutInfoTests: XCTestCase {
    func testVersionLineCombinesShortVersionAndBuild() {
        let info = AboutInfo(
            appVersion: "1.0", build: "1", gitCommit: "2c58b22",
            coreVersion: "0.1.0", apiVersions: [])
        XCTAssertEqual(info.versionLine, "1.0 (1)")
    }

    func testKnownApiVersionsCoverTheApisTheAppSends() {
        let names = Set(AboutInfo.knownApiVersions.map(\.name))
        for expected in [
            "SYNO.API.Auth", "SYNO.API.Info", "SYNO.Foto.Browse.Item",
            "SYNO.Foto.Thumbnail", "SYNO.Foto.Download",
            "SYNO.Foto.Search.Search", "SYNO.Foto.Search.Filter",
        ] {
            XCTAssertTrue(names.contains(expected), "missing \(expected)")
        }
    }

    func testKnownApiVersionsMatchTheDocumentedPinnedValues() {
        let byName = Dictionary(
            uniqueKeysWithValues: AboutInfo.knownApiVersions.map { ($0.name, $0.version) })
        XCTAssertEqual(byName["SYNO.API.Auth"], "3")
        XCTAssertEqual(byName["SYNO.API.Info"], "1")
        XCTAssertEqual(byName["SYNO.Foto.Thumbnail"], "2")
        XCTAssertEqual(byName["SYNO.Foto.Download"], "2")
        XCTAssertEqual(byName["SYNO.Foto.Search.Search"], "1")
    }

    func testCurrentPassesThroughInjectedGitCommitAndCoreVersion() {
        let info = AboutInfo.current(
            gitCommit: "deadbee",
            coreVersionProvider: { "9.9.9" })
        XCTAssertEqual(info.gitCommit, "deadbee")
        XCTAssertEqual(info.coreVersion, "9.9.9")
        XCTAssertFalse(info.apiVersions.isEmpty)
    }
}
