import XCTest
@testable import WebBridgeKit

final class WebBrowserSessionRestoreTests: XCTestCase {
    func testLocalPackageURLsAreNeverRestoredAfterColdLaunch() {
        let manager = WebBrowserManager()
        defer { manager.clearLastSession() }

        manager.persistLastSession(
            url: URL(fileURLWithPath: "/packages/app/versions/1/index.html")
        )
        XCTAssertNil(WebBrowserManager.restorableLastURL())
    }

    func testHTTPSURLsRemainRestorableInsideTheRecoveryWindow() {
        let manager = WebBrowserManager()
        defer { manager.clearLastSession() }
        let url = URL(string: "https://example.test/app")!

        manager.persistLastSession(url: url)
        XCTAssertEqual(WebBrowserManager.restorableLastURL(), url)
    }
}
