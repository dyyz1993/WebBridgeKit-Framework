//
//  HTMLAppHomeScreen.swift
//  WebBridgeKit
//

import Foundation
import UIKit

/// Host hook that turns a signed, already registered PWA manifest into a
/// trusted home-screen tile. The SDK deliberately does not own home UI or
/// activation storage.
public struct HTMLAppHomeScreenTarget: Equatable, Sendable {
    public let manifest: HTMLAppManifest
    public let documentURL: URL
    public let origin: String

    public init(manifest: HTMLAppManifest, documentURL: URL, origin: String) {
        self.manifest = manifest
        self.documentURL = documentURL
        self.origin = origin
    }
}

public enum HTMLAppHomeScreenResult: Equatable, Sendable {
    case added
    case alreadyPresent
}

public typealias HTMLAppHomeScreenPresenter = @Sendable (HTMLAppHomeScreenTarget) async throws -> HTMLAppHomeScreenResult

public extension Notification.Name {
    /// Posted after a host adds the current managed app to the home screen.
    static let htmlAppHomeScreenDidChange = Notification.Name(
        "com.webbridgekit.html-app.home-screen-did-change"
    )
}

/// Adds the currently registered managed PWA to the host's home screen. It is
/// a container action, not access to user data: the target cannot be chosen by
/// JavaScript and must match the registered manifest and current document
/// origin.
public final class WebAddToHomeScreenHandler: BaseWebNativeHandler {
    private let presenter: HTMLAppHomeScreenPresenter

    public init(presenter: @escaping HTMLAppHomeScreenPresenter) {
        self.presenter = presenter
        super.init()
    }

    public override convenience init() {
        self.init { target in
            guard let hostPresenter = WebBridgeHostCapabilityPolicy.homeScreenPresenter else {
                throw NSError(
                    domain: "WebBridgeKit.HomeScreen",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "宿主未提供添加到主页实现"]
                )
            }
            return try await hostPresenter(target)
        }
    }

    public override func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
        let params = body["params"] as? [String: Any] ?? body
        guard let reason = params["reason"] as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reject(error: "Invalid parameters: reason is required", completion: completion)
            return
        }
        runOnMainThread { [weak self] in
            guard let self else { return }
            guard let documentURL = self.webView?.url else {
                self.reject(error: "Current document is unavailable", completion: completion)
                return
            }
            guard let origin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: documentURL) else {
                self.reject(error: "无法识别页面来源，不能添加到主页", completion: completion)
                return
            }
            guard let context = WebBridgeHostCapabilityPolicy.homeScreenContext(
                documentURL: documentURL,
                origin: origin
            ) else {
                self.reject(error: "当前应用未注册，不能添加到主页", completion: completion)
                return
            }

            // placement=phoneHomeScreen 请求的是 iPhone 主屏幕添加引导（弹窗），
            // 不落 Drel 首页激活账本；由宿主提供的引导 UI 承接。
            if (params["placement"] as? String) == "phoneHomeScreen" {
                guard let guidePresenter = WebBridgeHostCapabilityPolicy.phoneHomeScreenGuidePresenter else {
                    self.reject(error: "宿主未提供主屏幕添加引导", completion: completion)
                    return
                }
                guidePresenter(context)
                self.resolve(
                    [
                        "action": "addToHomeScreen",
                        "placement": "phoneHomeScreen",
                        "appId": context.manifest.appID,
                        "name": context.manifest.name,
                        "result": "guidePresented"
                    ],
                    completion: completion
                )
                return
            }

            Task { @MainActor in
            do {
                    let result = try await self.presenter(context)
                    NotificationCenter.default.post(name: .htmlAppHomeScreenDidChange, object: context.manifest.appID)
                    self.resolve(
                    [
                        "action": "addToHomeScreen",
                        "appId": context.manifest.appID,
                        "name": context.manifest.name,
                        "version": context.manifest.effectiveOfflineCache.version,
                        "result": result == .alreadyPresent ? "alreadyPresent" : "added"
                    ],
                    completion: completion
                )
            } catch {
                    self.reject(error: error.localizedDescription, completion: completion)
            }
        }
    }
    }
}
