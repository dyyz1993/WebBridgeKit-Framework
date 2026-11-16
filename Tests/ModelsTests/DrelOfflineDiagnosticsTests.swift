import XCTest
@testable import WebBridgeKit

final class DrelOfflineDiagnosticsTests: XCTestCase {
    private var fileURL: URL!
    private var diagnostics: DrelOfflineDiagnostics!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrelOfflineDiagnosticsTests-\(UUID().uuidString).json")
        diagnostics = DrelOfflineDiagnostics(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testStoresOnlyWhitelistedDiagnosticsFields() throws {
        let attempt = diagnostics.beginAttempt(
            appID: "app.vot.19930810.xyz",
            packageVersion: "0.4.10.3",
            manifestDigestPrefix: String(repeating: "a", count: 64),
            source: "notification"
        )
        diagnostics.record(
            attemptID: attempt.id,
            phase: .package,
            status: .failed,
            path: "../../token?secret=value#/private",
            outcome: "token=secret"
        )
        diagnostics.record(
            attemptID: attempt.id,
            phase: .api,
            status: .failed,
            httpStatusCode: 999999,
            outcome: "apiFailed"
        )

        let report = diagnostics.copyReport()
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(report.contains("value"))
        XCTAssertFalse(report.contains("private"))
        XCTAssertTrue(report.contains("app.vot.19930810.xyz"))
        XCTAssertTrue(report.contains("controlled"))

        let stored = try XCTUnwrap(diagnostics.attempt(id: attempt.id))
        XCTAssertEqual(stored.manifestDigestPrefix, String(repeating: "a", count: 12))
        XCTAssertEqual(stored.events[1].path, "token")
        XCTAssertEqual(stored.events[2].httpStatusCode, 599)
    }

    func testRawUnknownErrorDomainIsControlledAndCodeIsNumeric() throws {
        struct SensitiveError: Error {}
        let attempt = diagnostics.beginAttempt(
            appID: "app.vot.shanbox.19930810.xyz",
            packageVersion: nil,
            manifestDigestPrefix: "not-a-digest",
            source: "unexpected"
        )
        diagnostics.record(
            attemptID: attempt.id,
            phase: .navigation,
            status: .failed,
            error: SensitiveError(),
            outcome: "navigationStarted"
        )
        let stored = try XCTUnwrap(diagnostics.attempt(id: attempt.id))
        XCTAssertEqual(stored.launchSource, "controlled")
        XCTAssertNil(stored.manifestDigestPrefix)
        XCTAssertEqual(stored.events.last?.errorDomain, "controlled")
        XCTAssertEqual(stored.events.last?.errorCode, 1)
    }

    func testKeepsOnlyLatestTwentyAttempts() {
        for index in 0..<25 {
            let attempt = diagnostics.beginAttempt(
                appID: "app.vot.19930810.xyz",
                packageVersion: String(index),
                manifestDigestPrefix: nil,
                source: "catalog"
            )
            diagnostics.record(
                attemptID: attempt.id,
                phase: .launch,
                status: .succeeded,
                outcome: "resolved"
            )
        }
        let attempts = diagnostics.attempts()
        XCTAssertEqual(attempts.count, DrelOfflineDiagnostics.maximumAttempts)
        XCTAssertEqual(
            Set(attempts.map { attempt in attempt.packageVersion ?? "" }).count,
            DrelOfflineDiagnostics.maximumAttempts
        )
    }
}
