import UIKit
import WebKit

public final class WebFullscreenHandler: BaseWebNativeHandler {
    public override func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
        let params = body["params"] as? [String: Any] ?? body
        guard let enabled = params["enabled"] as? Bool else {
            reject(error: "Fullscreen requires a Boolean enabled value", code: 400, completion: completion)
            return
        }

        runOnMainThread { [weak self] in
            guard let self, let webView = self.webView else {
                completion(["success": false, "error": "WebView is unavailable"])
                return
            }
            NotificationCenter.default.post(
                name: .webBridgeKitFullscreenChanged,
                object: webView,
                userInfo: ["enabled": enabled]
            )
            self.resolve(["fullscreen": enabled], completion: completion)
        }
    }
}

public extension Notification.Name {
    static let webBridgeKitFullscreenChanged = Notification.Name("WebBridgeKitFullscreenChanged")
}
