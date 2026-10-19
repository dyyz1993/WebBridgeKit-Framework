//
//  WebShareHandler.swift
//  WebBridgeKit
//
//  Created by Claude on 2025-01-13.
//  Copyright © 2025年 WebBridgeKit. All rights reserved.
//

import Foundation
import UIKit
import WebKit

// Framework imports

/// 分享处理器
public class WebShareHandler: BaseWebNativeHandler {

    /// 处理分享请求
    /// - Parameters:
    ///   - body: 包含 text 和 url
    ///   - completion: 结果回调
    public override func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
        // 兼容 body 或 body.params
        let params = body["params"] as? [String: Any] ?? body
        let parsedIconURL: URL? = (params["iconURL"] as? String).flatMap(URL.init(string:))
        let iconURL: URL? = {
            guard let parsed = parsedIconURL, parsed.scheme?.lowercased() == "https" else { return nil }
            return parsed
        }()
        // Only same-origin icons are accepted. A remote declaration cannot ask
        // Drel to fetch arbitrary third-party image URLs.
        let sameOriginIcon = iconURL.flatMap { icon -> URL? in
            guard let documentOrigin = webView?.url.flatMap(HTMLAppOrigin.canonicalOrigin(forDocumentURL:)),
                  let iconOrigin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: icon),
                  documentOrigin == iconOrigin else {
                return nil
            }
            return icon
        }

        guard let text = params["text"] as? String,
              let urlString = params["url"] as? String,
              let url = URL(string: urlString) else {
            reject(error: "Invalid parameters: text and url are required", completion: completion)
            return
        }

        // 在主线程执行分享
        runOnMainThread {
            if let sameOriginIcon {
                Self.downloadIcon(sameOriginIcon) { image in
                    self.presentShare(
                        text: text,
                        url: url,
                        icon: image,
                        completion: completion
                    )
                }
            } else {
                self.presentShare(text: text, url: url, icon: nil, completion: completion)
            }
        }
    }

    private static func downloadIcon(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let image = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap(UIImage.init(data:))
                : nil
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    private func presentShare(
        text: String,
        url: URL,
        icon: UIImage?,
        completion: @escaping (Any) -> Void
    ) {
        var items: [Any] = [text, url]
        if let icon {
            items.append(icon)
        }
        let activityViewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let topVC = topViewController {
            topVC.present(activityViewController, animated: true) {
                self.resolve(completion: completion)
            }
        } else {
            reject(error: "No view controller", completion: completion)
        }
    }
}
