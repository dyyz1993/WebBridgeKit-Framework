import XCTest
@testable import WebBridgeKit

@MainActor
final class ImmersivePWAExitControlLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "com.webbridgekit.immersive-exit.edge")
        UserDefaults.standard.removeObject(forKey: "com.webbridgekit.immersive-exit.vertical-ratio")
    }

    func testCollapsedLeftControlUsesAOneThirdNarrowerSliver() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let control = ImmersivePWAExitControl()
        host.addSubview(control)

        control.updateLayout(in: host)

        XCTAssertEqual(control.frame.maxX, 20, accuracy: 0.5)
        let arrow = try XCTUnwrap(control.subviews.compactMap { $0 as? UIImageView }.first)
        let arrowFrame = control.convert(arrow.frame, to: host)
        XCTAssertGreaterThanOrEqual(arrowFrame.minX, -0.5)
        XCTAssertLessThanOrEqual(arrowFrame.maxX, control.frame.maxX + 0.5)
    }
}
