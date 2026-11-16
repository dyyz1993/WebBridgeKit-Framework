import UIKit

extension WebViewController {
    func applyConfiguredOrientation() {
        guard let config = browserConfig else { return }
        switch config.orientation {
        case .landscapeLeft:
            rotateTo(.landscapeLeft)
            StructuredLogger.shared.debug("viewWillAppear - Forcing landscapeLeft orientation", category: .ui)
        case .landscapeRight:
            rotateTo(.landscapeRight)
            StructuredLogger.shared.debug("viewWillAppear - Forcing landscapeRight orientation", category: .ui)
        case .landscape:
            rotateTo(.landscapeLeft)
            StructuredLogger.shared.debug("viewWillAppear - Forcing landscape (left) orientation", category: .ui)
        case .portrait:
            rotateTo(.portrait)
            StructuredLogger.shared.debug("viewWillAppear - Forcing portrait orientation", category: .ui)
        default:
            break
        }
    }

    func confirmConfiguredOrientationAfterAppear() {
        guard let config = browserConfig else { return }
        let orientation: UIInterfaceOrientation
        let label: String
        switch config.orientation {
        case .landscapeLeft:
            orientation = .landscapeLeft
            label = "landscapeLeft"
        case .landscapeRight:
            orientation = .landscapeRight
            label = "landscapeRight"
        case .landscape:
            orientation = .landscapeLeft
            label = "landscape (left)"
        case .portrait:
            orientation = .portrait
            label = "portrait"
        default:
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rotateTo(orientation)
            StructuredLogger.shared.debug("viewDidAppear - Final forcing \(label) orientation", category: .ui)
        }
    }
}
