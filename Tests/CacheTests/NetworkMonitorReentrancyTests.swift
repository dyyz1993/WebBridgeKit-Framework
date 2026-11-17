import XCTest
@testable import WebBridgeKit

/// The connectivity getters take the shared NSLock; every public helper that
/// reads state while holding that lock must read the backing variables
/// directly. NSLock is not reentrant, so a getter call inside the locked
/// region deadlocks the calling thread. These tests invoke every public
/// reader from a detached thread with a hard timeout: a deadlock hangs the
/// detached thread, the timeout expires, and the test fails instead of
/// hanging the suite.
final class NetworkMonitorReentrancyTests: XCTestCase {
    private let monitor = NetworkMonitor.shared

    func testPublicReadersCompleteWithoutDeadlock() async throws {
        let readers: [(name: String, work: () -> Void)] = [
            ("isConnected", { _ = self.monitor.isConnected }),
            ("isConnectivityKnown", { _ = self.monitor.isConnectivityKnown }),
            ("connectionType", { _ = self.monitor.connectionType }),
            ("connectivitySnapshot", { _ = self.monitor.connectivitySnapshot() }),
            ("isCellular", { _ = self.monitor.isCellular() }),
            ("isWiFi", { _ = self.monitor.isWiFi() }),
            ("getStatusDescription", { _ = self.monitor.getStatusDescription() }),
            ("ensureNetworkAvailable", { try? self.monitor.ensureNetworkAvailable() }),
            ("warnIfCellular", { _ = self.monitor.warnIfCellular() })
        ]

        for reader in readers {
            let done = expectation(description: "reader: \(reader.name)")
            DispatchQueue.global(qos: .userInitiated).async {
                reader.work()
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 3)
        }
    }

    func testConcurrentReadersDoNotDeadlockOrCrash() async throws {
        let finished = expectation(description: "concurrent readers")
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            switch index % 5 {
            case 0: _ = monitor.isConnected
            case 1: _ = monitor.isCellular()
            case 2: _ = monitor.getStatusDescription()
            case 3: _ = monitor.connectivitySnapshot()
            default: _ = monitor.warnIfCellular()
            }
        }
        finished.fulfill()
        await fulfillment(of: [finished], timeout: 10)
    }

    func testStatusDescriptionValuesAreBounded() {
        let description = monitor.getStatusDescription()
        XCTAssertTrue(
            ["Offline", "WiFi", "Cellular", "Ethernet", "Unknown"].contains(description)
        )
    }
}
