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

    func testImmersiveOfflinePackageFallbackRunsOnlyOncePerManagedSession() {
        let viewModel = WebBrowserViewModel(url: URL(fileURLWithPath: "/tmp/package/index.html"))

        XCTAssertTrue(viewModel.beginOfflinePackageFallback())
        XCTAssertFalse(viewModel.beginOfflinePackageFallback())

        viewModel.configureManagedHTMLApp(
            appID: "app.example",
            documentURL: URL(string: "https://example.test/app")
        )
        XCTAssertTrue(viewModel.beginOfflinePackageFallback())
    }

    func testStoreBrowserPreservesTrustedOfflineFallbackContextWithoutNativeBridge() {
        let previousOverride = WebBridgeHostCapabilityPolicy.containerOnlyOverride
        WebBridgeHostCapabilityPolicy.containerOnlyOverride = true
        defer { WebBridgeHostCapabilityPolicy.containerOnlyOverride = previousOverride }

        let localEntrypoint = URL(fileURLWithPath: "/tmp/package/drel.html")
        let controller = WebBrowserViewController(url: localEntrypoint)
        let trustedPageURL = URL(string: "https://vot.example.test/")!
        let appID = "app.vot.example.test"

        controller.configure(
            with: WebBrowserParams(
                displayMode: .immersive,
                payload: [
                    "webbridgekitAppId": appID,
                    "webbridgekitPageURL": trustedPageURL.absoluteString,
                    "webbridgekitOfflineMode": "strong"
                ],
                useManifestLoader: false
            )
        )

        XCTAssertEqual(controller.htmlAppID, appID)
        XCTAssertEqual(controller.viewModel.offlinePackageFallbackDocumentURL, trustedPageURL)

        controller.viewModel.updateManagedHTMLAppDocumentURL(localEntrypoint)
        XCTAssertEqual(controller.viewModel.managedHTMLAppDocumentURL, localEntrypoint)
        XCTAssertEqual(controller.viewModel.offlinePackageFallbackDocumentURL, trustedPageURL)
        XCTAssertTrue(controller.viewModel.beginOfflinePackageFallback())
    }
}
