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
import LinkPresentation

// Framework imports

/// 分享预览项：让 iOS 分享面板顶部显示「应用名 + 应用图标 + 链接」。
///
/// 之前直接把 [text, url] 丢给 UIActivityViewController，iOS 会拿 URL item
/// 的 host 当标题（实测显示成 example.com），应用图标也无从传入。
/// 2026-10-22 用户实测反馈后改为显式提供预览源：标题取当前注册应用名，
/// 缩略图取该应用的 Web App Manifest 图标，链接仍是网页传入的目标 URL。
private final class SharePreviewItemSource: NSObject, UIActivityItemSource {
    let title: String
    let subtitle: String
    let url: URL
    let icon: UIImage?

    init(title: String, subtitle: String, url: URL, icon: UIImage?) {
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.icon = icon
        super.init()
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // 拷贝类活动（备忘录/邮件等）只需要文本本身。
        // 用字符串字面量而非 UIActivity.ActivityType.copy：该静态成员在较低
        // 部署目标上不可用，且泛型推断在这里会与 Optional 比较冲突。
        let type = activityType?.rawValue ?? ""
        if type == "com.apple.UIKit.activity.CopyToPasteboard" || type == "com.apple.UIKit.activity.Mail" {
            return "\(title)\n\(subtitle)\n\(url.absoluteString)"
        }
        return url
    }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let icon {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}

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
        // 图标来源优先级：网页传入的同源 https 图标 → 当前注册应用的 Web App
        // Manifest 图标（同源）。第三方图床地址一律不接受——远程页面不能
        // 让 Drel 去抓任意图片 URL。
        let documentOrigin = webView?.url.flatMap(HTMLAppOrigin.canonicalOrigin(forDocumentURL:))
        let sameOriginIcon = iconURL.flatMap { icon -> URL? in
            guard let documentOrigin,
                  let iconOrigin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: icon),
                  documentOrigin == iconOrigin else {
                return nil
            }
            return icon
        }
        let manifestIcon = currentAppIcon(documentOrigin: documentOrigin)

        guard let text = params["text"] as? String,
              let urlString = params["url"] as? String,
              let url = URL(string: urlString) else {
            reject(error: "Invalid parameters: text and url are required", completion: completion)
            return
        }

        // 在主线程执行分享
        runOnMainThread {
            let iconCandidate = sameOriginIcon ?? manifestIcon
            if let iconCandidate {
                Self.downloadIcon(iconCandidate) { image in
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

    /// 当前注册应用的 Web App Manifest 图标（必须 https 且与文档同源）
    private func currentAppIcon(documentOrigin: String?) -> URL? {
        guard let documentOrigin,
              let documentURL = webView?.url,
              let manifest = HTMLAppRuntimeCenter.shared.trustRegistry.registeredManifests()
                .first(where: { $0.allows(documentURL: documentURL) }),
              let icon = HTMLAppPresentationMetadataStore().metadata(for: manifest.appID)?.iconURLs.last,
              icon.scheme?.lowercased() == "https",
              let iconOrigin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: icon),
              iconOrigin == documentOrigin else {
            return nil
        }
        return icon
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
        // 标题优先用当前注册应用名（manifest / Web App Manifest 元数据），
        // 分享面板顶部就不再是网页 URL 的 host（2026-10-22 实测修复）
        let appName = currentAppName() ?? (webView?.url?.host ?? "网页应用")
        let preview = SharePreviewItemSource(
            title: appName,
            subtitle: text,
            url: url,
            icon: icon
        )
        let activityViewController = UIActivityViewController(activityItems: [preview], applicationActivities: nil)
        if let topVC = topViewController {
            topVC.present(activityViewController, animated: true) {
                self.resolve(completion: completion)
            }
        } else {
            reject(error: "No view controller", completion: completion)
        }
    }

    /// 当前 WebView 对应的注册应用名：优先 Web App Manifest 的展示名，
    /// 回落到签名父 manifest 的应用名。
    private func currentAppName() -> String? {
        guard let documentURL = webView?.url else { return nil }
        guard let manifest = HTMLAppRuntimeCenter.shared.trustRegistry.registeredManifests()
            .first(where: { $0.allows(documentURL: documentURL) }) else { return nil }
        return HTMLAppPresentationMetadataStore().metadata(for: manifest.appID)?.name ?? manifest.name
    }
}
