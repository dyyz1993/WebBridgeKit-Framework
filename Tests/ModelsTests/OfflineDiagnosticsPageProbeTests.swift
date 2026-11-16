import XCTest
import WebKit
@testable import WebBridgeKit

/// Regression coverage for the offline page-readiness probe script.
///
/// The WKUserScript injection channel does not deliver in framework
/// unit-test bundles without a host application, so the script under test is
/// evaluated explicitly with evaluateJavaScript against the same DOM
/// scenarios. The injection and message-handler path is exercised by the
/// Drel UI suite (OfflineVOTDiagnosticsTests) on a real app host.
///
/// Pinned behaviors:
/// 1. Media hidden by CSS (display/visibility) must not count as visible
///    content; the previous implementation only excluded the "hidden"
///    attribute.
/// 2. Content that renders after the first evaluation must still be
///    detected by the bounded watch; the previous implementation reported
///    exactly once, so late-rendering pages were misjudged as failed and
///    triggered an unnecessary online fallback.
///
/// Scope: these tests prove the listed DOM strategies. They do not claim
/// the probe is reliable for arbitrary pages (custom zero-size WebGL
/// canvases, shadow-DOM-only trees, or intentionally empty pages still end
/// in the documented timeout/fallback path).
@MainActor
final class OfflineDiagnosticsPageProbeTests: XCTestCase {
    private final class Box {
        var value = false
    }

    private final class MessageRecorder: NSObject, WKScriptMessageHandler {
        var pageReadyReports: [[String: Any]] = []

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  body["event"] as? String == "pageReady" else { return }
            pageReadyReports.append(body)
        }
    }

    private var webView: WKWebView?
    private var recorder: MessageRecorder?

    private static var didWarmUpWebContent = false

    override func tearDown() {
        webView = nil
        recorder = nil
        super.tearDown()
    }

    private func makeWebView(pageHTML: String = "<!doctype html><html><body></body></html>") throws -> MessageRecorder {
        warmUpWebContentIfNeeded()
        let recorder = MessageRecorder()
        let controller = WKUserContentController()
        controller.add(recorder, name: WebViewController.offlineDiagnosticsMessageName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        self.webView = webView
        self.recorder = recorder

        webView.loadHTMLString(pageHTML, baseURL: nil)
        let readyBox = Box()
        let documentReady = pumpUntil(seconds: 30) {
            webView.evaluateJavaScript("document.readyState === 'complete'") { value, _ in
                readyBox.value = (value as? Bool) == true
            }
            return readyBox.value
        }
        XCTAssertTrue(documentReady, "Document should finish loading")

        var scriptError: Error?
        let installed = expectation(description: "installed")
        webView.evaluateJavaScript(WebViewController.offlineDiagnosticsScript) { _, error in
            scriptError = error
            installed.fulfill()
        }
        wait(for: [installed], timeout: 5)
        XCTAssertNil(scriptError, "probe script failed to evaluate")
        return recorder
    }

    /// The first WKWebView in an unhosted unit-test process has a slow,
    /// sometimes messageless cold start. A throwaway load settles the
    /// WebContent process so the actual probes run against a warm process.
    private func warmUpWebContentIfNeeded() {
        guard !Self.didWarmUpWebContent else { return }
        Self.didWarmUpWebContent = true
        let warmView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: WKWebViewConfiguration()
        )
        warmView.loadHTMLString("<!doctype html><html><body>warm</body></html>", baseURL: nil)
        let readyBox = Box()
        _ = pumpUntil(seconds: 40) {
            warmView.evaluateJavaScript("document.readyState === 'complete'") { value, _ in
                readyBox.value = (value as? Bool) == true
            }
            return readyBox.value
        }
        let settle = Date().addingTimeInterval(1.5)
        while Date() < settle {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func pumpUntil(seconds: TimeInterval, satisfied: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if satisfied() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return satisfied()
    }

    private func appendContent(_ fragment: String) throws {
        let appended = expectation(description: "appended")
        webView?.evaluateJavaScript(
            "(() => { const wrapper = document.createElement('div'); wrapper.innerHTML = \""
                + fragment + "\"; document.body.appendChild(wrapper); return 'ok'; })()"
        ) { _, error in
            XCTAssertNil(error, "append failed")
            appended.fulfill()
        }
        wait(for: [appended], timeout: 5)
    }

    func testCSSHiddenMediaDoesNotCountAsVisibleContent() throws {
        let recorder = try makeWebView()
        let initialMiss = pumpUntil(seconds: 10) {
            recorder.pageReadyReports.contains { ($0["keyElementFound"] as? Bool) == false }
        }
        XCTAssertTrue(initialMiss, "Empty page should report an initial miss")

        try appendContent(
            "<canvas style='display:none' width='300' height='150'></canvas>"
                + "<svg style='visibility:hidden' width='120' height='120'></svg>"
        )
        let falseSuccess = pumpUntil(seconds: 2.5) {
            recorder.pageReadyReports.contains { ($0["keyElementFound"] as? Bool) == true }
        }
        XCTAssertFalse(
            falseSuccess,
            "CSS-hidden media must not count as visible content: " + recorder.pageReadyReports.description
        )
    }

    func testLateRenderedContentIsDetectedByBoundedWatch() throws {
        let recorder = try makeWebView()
        let initialMiss = pumpUntil(seconds: 10) {
            recorder.pageReadyReports.contains { ($0["keyElementFound"] as? Bool) == false }
        }
        XCTAssertTrue(initialMiss, "Empty page should report an initial miss")

        try appendContent("<h1>已加载</h1>")
        let detected = pumpUntil(seconds: 4) {
            recorder.pageReadyReports.contains { ($0["keyElementFound"] as? Bool) == true }
        }
        XCTAssertTrue(
            detected,
            "Late render inside the watch window must be detected: " + recorder.pageReadyReports.description
        )
    }

    func testImmediatelyVisibleTextReportsReadyOnce() throws {
        let recorder = try makeWebView(
            pageHTML: "<!doctype html><html><body><h1>登录</h1></body></html>"
        )
        let detected = pumpUntil(seconds: 3) {
            recorder.pageReadyReports.contains { ($0["keyElementFound"] as? Bool) == true }
        }
        XCTAssertTrue(detected, "Visible body text should report ready: " + recorder.pageReadyReports.description)
        XCTAssertLessThanOrEqual(
            recorder.pageReadyReports.count,
            1,
            "A ready page must not produce repeated pageReady reports"
        )
    }

    func testScriptGuardsAgainstDoubleInstall() throws {
        let recorder = try makeWebView()
        _ = pumpUntil(seconds: 3) {
            recorder.pageReadyReports.count >= 1
        }
        let reportsAfterFirstInstall = recorder.pageReadyReports.count
        var secondRunValue = "pending"
        let secondRun = expectation(description: "second run")
        webView?.evaluateJavaScript(WebViewController.offlineDiagnosticsScript) { value, _ in
            secondRunValue = String(describing: value)
            secondRun.fulfill()
        }
        wait(for: [secondRun], timeout: 5)
        XCTAssertEqual(secondRunValue, "nil", "Guarded second install must return undefined")
        XCTAssertEqual(
            recorder.pageReadyReports.count,
            reportsAfterFirstInstall,
            "Second install must not add reports"
        )
    }
}
