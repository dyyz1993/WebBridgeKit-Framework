//
//  WebJavaScriptBridge.swift
//  WebBridgeKit
//
//  Created by Claude on 2025-01-13.
//  Copyright © 2025年 WebBridgeKit. All rights reserved.
//

import Foundation
import WebKit
import UIKit

private final class WBKUserGestureRecognizer: UIGestureRecognizer {
    private let lock = NSLock()
    private(set) var lastTouchAt: Date?

    func consumeRecentUserGesture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastTouchAt, Date().timeIntervalSince(lastTouchAt) <= 1.5 else { return false }
        self.lastTouchAt = nil
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        lock.lock()
        lastTouchAt = Date()
        lock.unlock()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

// Framework imports

/// JS-OC 通信桥接核心类
public class WebJavaScriptBridge: NSObject, WKScriptMessageHandler {

    // MARK: - Properties

    public var nativeHandlers: [String: WebNativeAPI] = [:]  // 改为 public，供 WebTestViewController 访问
    private var handlerFactories: [String: () -> WebNativeAPI] = [:]  // Handler 工厂方法，用于懒加载
    private weak var webView: WKWebView?
    private var userGestureRecognizer: WBKUserGestureRecognizer?
    var userGestureValidationOverride: (() -> Bool)?
    private var managedAppID: String?
    private var managedDocumentURL: URL?
    private var managedLaunchPageURL: URL?
    private let offlinePackageLocator: HTMLAppOfflinePackageLocator
    public weak var permissionConsentPresenter: HTMLAppPermissionConsentPresenting?
    private let trustRegistry: HTMLAppTrustRegistry
    private let permissionLedger: HTMLAppPermissionLedger
    private let nativeAuthorizationProvider: HTMLAppNativeAuthorizationProviding
    private let capabilityGateway: HTMLAppCapabilityGateway
    private let offlineFallbackSignatureVerifier: ((HTMLAppManifest) -> Bool)?
    private let isOfflineProvider: (() -> Bool)?
    private let gatewayIdentity: String?
    private struct PendingAuthorization {
        let subject: HTMLAppPermissionSubject
        let documentURL: URL
        let request: HTMLAppCapabilityRequest
        let completion: (AuthorizationDecision) -> Void
    }
    private let pendingAuthorizationsLock = NSLock()
    private var pendingAuthorizations: [String: PendingAuthorization] = [:]
    private var permissionRevocationObserver: NSObjectProtocol?
    private var audioBackgroundObserver: NSObjectProtocol?
    public var currentCallbackId: String?  // 改为 public，供 WebTestViewController 访问
    private let handlersLock = NSLock()  // 线程安全锁
    private let audioSessionLock = NSLock()
    private var audioSessionGeneration = 0

    private func audioGeneration(invalidate: Bool = false) -> Int {
        audioSessionLock.lock()
        defer { audioSessionLock.unlock() }
        if invalidate { audioSessionGeneration += 1 }
        return audioSessionGeneration
    }

    private func stopAudioForSessionEnd() {
        _ = audioGeneration(invalidate: true)
        cancelManagedGatewayRequests()
        handlersLock.lock()
        let audio = nativeHandlers["audioLevel"] as? HTMLAppCapabilityRevocationHandling
        handlersLock.unlock()
        audio?.htmlAppCapabilityDidRevoke()
    }

    private func cancelManagedGatewayRequests() {
        guard let appID = managedAppID,
              let url = effectiveManagedDocumentURL(webView?.url ?? managedDocumentURL),
              let origin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: url),
              let subject = permissionSubject(appID: appID, origin: origin) else { return }
        capabilityGateway.cancelPendingRequests(subject: subject)
    }

    // 活跃的请求 Token（用于自动日志）
    private var activeTokens: [String: WebBridgeLogToken] = [:]
    private let tokensLock = NSLock()

    // MARK: - Command Trace History

    /// 命令执行历史记录（最多保留 100 条）
    private var commandHistory: [CommandTraceEntry] = []
    private let historyLock = NSLock()
    private let maxHistorySize = 100

    // MARK: - Security: Command Allowlist

    /// 允许的 JS Bridge 命令列表（安全边界）
    /// 在开发模式下可以放宽限制，但生产环境必须严格验证
    private static let ALLOWED_COMMANDS: Set<String> = [
        // 基础功能
        "share",
        "getCapabilities",
        "getLocation",
        "requestPermission",
        // 系统信息
        "getSystemInfo",
        "getNetworkInfo",
        // 交互反馈
        "haptic",
        "vibrate",
        // 宿主显示模式
        "fullscreen",
        // 剪贴板
        "clipboard",
        // 扫码
        "scan",
        // 添加到主页（宿主注册实现）
        "addToHomeScreen",
        // 相机
        "camera",
        // 视频流
        "videoStream",
        // 语音识别
        "speech",
        // 实时音频音量监控
        "audioLevel",
        // 通讯录
        "contacts",
        // 屏幕控制
        "screen",
        // 布局控制
        "layout",
        // 投屏控制
        "mirroring",
        // 传感器控制
        "sensors",
        // 媒体与文件
        "media",
        // 系统增强
        "systemExtra",
        // 语音合成
        "tts",
        // 蓝牙控制
        "bluetooth",
        // 文件选择
        "file",
        // 权限状态查询
        "getPermissionStatus",
        // 打开系统设置
        "openSettings",
        // 打开本地页面
        "openPage",
        // 关闭当前页面
        "closePage",
        // 获取导航历史
        "getHistory",
        // 获取透传参数
        "getPayload",
        // 后退
        "goBack",
        // 设置弹窗参数
        "setModal",
        // 手势监控
        "gesture",
        // 缓存调试
        "cacheDebug",
        // 页面缓存管理
        "page",
        // 本地通知（非 APNs）
        "showNotification",
        // 相册选择 (iOS 14+)
        "photo"
    ]

    // MARK: - Initialization

    public override convenience init() {
        self.init(
            trustRegistry: HTMLAppRuntimeCenter.shared.trustRegistry,
            permissionLedger: HTMLAppRuntimeCenter.shared.permissionLedger,
            nativeAuthorizationProvider: HTMLAppRuntimeCenter.shared.systemPermissionAdapter,
            gatewayIdentity: nil,
            offlineFallbackSignatureVerifier: HTMLAppOfflineFallbackRuntime.signatureVerifier,
            isOfflineProvider: HTMLAppOfflineFallbackRuntime.isOfflineProvider
        )
    }

    public init(
        trustRegistry: HTMLAppTrustRegistry,
        permissionLedger: HTMLAppPermissionLedger,
        nativeAuthorizationProvider: HTMLAppNativeAuthorizationProviding,
        gatewayIdentity: String? = "test-gateway",
        offlinePackageLocator: HTMLAppOfflinePackageLocator = HTMLAppOfflinePackageLocator(),
        offlineFallbackSignatureVerifier: ((HTMLAppManifest) -> Bool)? = nil,
        isOfflineProvider: (() -> Bool)? = nil
    ) {
        self.trustRegistry = trustRegistry
        self.permissionLedger = permissionLedger
        self.nativeAuthorizationProvider = nativeAuthorizationProvider
        self.gatewayIdentity = gatewayIdentity
        self.offlinePackageLocator = offlinePackageLocator
        self.offlineFallbackSignatureVerifier = offlineFallbackSignatureVerifier
        self.isOfflineProvider = isOfflineProvider
        capabilityGateway = HTMLAppCapabilityGateway(
            trustRegistry: trustRegistry,
            permissionLedger: permissionLedger,
            nativeAuthorizationProvider: nativeAuthorizationProvider
        )
        super.init()
        permissionConsentPresenter = HTMLAppPermissionPromptPresenter.shared
        permissionRevocationObserver = NotificationCenter.default.addObserver(
            forName: .htmlAppPermissionDidRevoke,
            object: permissionLedger,
            queue: nil
        ) { [weak self] notification in
            self?.handlePermissionRevocation(notification)
        }
        audioBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stopAudioForSessionEnd() }
        registerHandlerFactories()  // 只注册工厂方法，不创建实例
    }

    deinit {
        endManagedHTMLAppSession()
        if let permissionRevocationObserver {
            NotificationCenter.default.removeObserver(permissionRevocationObserver)
        }
        if let audioBackgroundObserver { NotificationCenter.default.removeObserver(audioBackgroundObserver) }
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            WebBridgeLogger.shared.error("Invalid message format")
            sendErrorToJS("Invalid message format", callbackId: nil)
            return
        }
        handle(body: body) { [weak self] result, callbackID in
            self?.sendResultToJS(result, callbackId: callbackID)
        }
    }

    /// 页面 meta 声明身份（didFinish 时由宿主通过 extractionScript 读取回填）。
    /// nil = 页面未声明，维持 origin 身份（完全向后兼容）。
    private(set) var declaredIdentity: HTMLAppDeclaredIdentity?

    /// 宿主在导航完成后调用：读取页面 meta 声明并应用到判定链。
    public func updateDeclaredIdentity(from extractionResult: Any?) {
        declaredIdentity = HTMLAppDeclaredIdentity.parse(extractionResult: extractionResult)
        WBKGateTrace.log("declaredIdentity=\(self.declaredIdentity?.namespacedAppID ?? "nil")")
    }

    public func refreshDeclaredIdentity() {
        guard let webView else { return }
        webView.evaluateJavaScript(HTMLAppDeclaredIdentity.extractionScript) { [weak self] result, _ in
            self?.updateDeclaredIdentity(from: result)
        }
    }

    public func configureManagedHTMLApp(appID: String?, documentURL: URL?) {
        let previousAppID = managedAppID
        let previousURL = managedDocumentURL
        let previousOrigin = previousURL.flatMap(HTMLAppOrigin.canonicalOrigin(forDocumentURL:))
        let nextOrigin = documentURL.flatMap(HTMLAppOrigin.canonicalOrigin(forDocumentURL:))
        if let previousAppID,
           previousAppID != appID || previousOrigin != nextOrigin {
            endManagedHTMLAppSession(appID: previousAppID, documentURL: previousURL)
        }
        managedAppID = appID
        managedDocumentURL = documentURL
        managedLaunchPageURL = documentURL
    }

    public func updateManagedHTMLAppDocumentURL(_ documentURL: URL?) {
        let launchPageURL = managedLaunchPageURL
        configureManagedHTMLApp(appID: managedAppID, documentURL: documentURL)
        managedLaunchPageURL = launchPageURL
    }

    public func endManagedHTMLAppSession() {
        endManagedHTMLAppSession(appID: managedAppID, documentURL: managedDocumentURL ?? webView?.url)
        managedAppID = nil
        managedDocumentURL = nil
        managedLaunchPageURL = nil
    }

    private func endManagedHTMLAppSession(appID: String?, documentURL: URL?) {
        stopAudioForSessionEnd()
        guard let appID else { return }
        cancelPendingAuthorizations(appID: appID)
        guard let documentURL = effectiveManagedDocumentURL(documentURL),
              let origin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: documentURL) else { return }
        guard let subject = permissionSubject(appID: appID, origin: origin) else { return }
        permissionLedger.revokeSessionGrants(subject: subject)
    }

    private func handlePermissionRevocation(_ notification: Notification) {
        guard let revocation = notification.userInfo?[HTMLAppPermissionRevocationNotification.payloadKey]
                as? HTMLAppPermissionRevocation,
              revocation.appID == managedAppID else {
            return
        }
        let documentURL = effectiveManagedDocumentURL(webView?.url ?? managedDocumentURL)
        guard let documentURL,
              HTMLAppOrigin.canonicalOrigin(forDocumentURL: documentURL) == revocation.origin else {
            return
        }

        if revocation.capability == .microphone {
            _ = audioGeneration(invalidate: true)
            cancelManagedGatewayRequests()
        }

        handlersLock.lock()
        let handlers = nativeHandlers.compactMap { action, handler -> HTMLAppCapabilityRevocationHandling? in
            guard HTMLAppBridgeCapabilityPolicy.capability(for: action, body: [:]) == revocation.capability else {
                return nil
            }
            return handler as? HTMLAppCapabilityRevocationHandling
        }
        handlersLock.unlock()

        DispatchQueue.main.async {
            handlers.forEach { $0.htmlAppCapabilityDidRevoke() }
        }
    }

    /// Shared dispatch path for WKScriptMessageHandler and host containers that
    /// proxy script messages through their own navigation controller.
    public func handle(
        body: [String: Any],
        completion: @escaping (_ result: Any, _ callbackID: String?) -> Void
    ) {
        guard let action = body["action"] as? String else {
            completion(WebBridgeResponse.error(code: 400, message: "Invalid message format"), nil)
            return
        }

        //  Security: Validate command against allowlist
        guard Self.ALLOWED_COMMANDS.contains(action) else {
            let error = "Command not allowed: \(action)"
            Log.error(error, category: .general)
            WebBridgeLogger.shared.log(.error, "[JS Bridge] \(error)")
            StructuredLogger.shared.error("[FAIL] [JS Bridge] Blocked unknown command: \(action)", category: .bridge)

            // 添加到历史记录（标记为失败）
            let callbackId = body["callbackId"] as? String ?? body["messageId"] as? String
            let trace = CommandTraceEntry(
                action: action,
                input: body,
                timestamp: Date(),
                callbackId: callbackId,
                status: .failed
            )
            addCommandToHistory(trace)

            completion(WebBridgeResponse.error(code: 403, message: error), callbackId)
            return
        }

        if let allowedActions = WebBridgeHostCapabilityPolicy.nativeActionAllowlist,
           !allowedActions.contains(action) {
            completion(WebBridgeResponse.error(code: 403, message: "Action is not enabled by the host policy"),
                       body["callbackId"] as? String ?? body["messageId"] as? String)
            return
        }

        // 获取 callbackId，避免并发时被覆盖。旧版 WebBridge.js 使用 messageId，
        // 这里保留兼容，避免真实 WKWebView Promise 回调无法 resolve。
        let callbackId = body["callbackId"] as? String ?? body["messageId"] as? String
        WBKGateTrace.log("handle action=\(action) cb=\(callbackId ?? "-") self=\(ObjectIdentifier(self))")

        // Read-only: no authorization flow, gesture consumption or permission UI.
        if action == "getCapabilities" {
            completion(WebBridgeResponse.success(data: capabilitySnapshot()).toDictionary(), callbackId)
            return
        }

        // 创建命令跟踪条目
        let trace = CommandTraceEntry(
            action: action,
            input: body,
            timestamp: Date(),
            callbackId: callbackId,
            status: .received
        )

        // 添加到历史记录
        addCommandToHistory(trace)

        guard let handler = getHandler(for: action) else {
            WebBridgeLogger.shared.error("Unsupported action: \(action)")
            completion(WebBridgeResponse.error(code: 404, message: "Unsupported action: \(action)"), callbackId)

            // 更新跟踪状态为失败
            updateCommandStatus(action: action, status: .failed, error: "Unsupported action")

            return
        }

        let params = body["params"] as? [String: Any] ?? body
        // Stopping capture must never require a new gesture or prompt.
        let isAudioStop = action == "audioLevel" && params["action"] as? String == "stop"
        let audioGenerationAtRequest = audioGeneration(invalidate: isAudioStop)
        if isAudioStop { cancelManagedGatewayRequests() }
        let authorize: (@escaping (AuthorizationDecision) -> Void) -> Void = { done in
            if isAudioStop { done(.allowed) }
            else { self.authorizeIfNeeded(action: action, body: body, completion: done) }
        }
        authorize { [weak self] authorization in
            guard let self else {
                completion(Self.authorizationError(
                    capability: HTMLAppBridgeCapabilityPolicy.capability(for: action, body: body) ?? .deviceControl,
                    status: .denied,
                    message: "PWA 容器已关闭"
                ), callbackId)
                return
            }
            // iOS 系统层已拒绝：弹原生引导（含「前往系统设置」入口），不再
            // 只把错误文字丢回 JS——用户需要一个可操作的路径去开启。
            if case .denied(let result) = authorization,
               let status = result["status"] as? String, status == "requiresSettings" {
                DispatchQueue.main.async {
                    let alert = UIAlertController(
                        title: "系统权限已关闭",
                        message: (result["error"] as? String) ?? "iOS 系统层已拒绝该能力，请前往系统设置开启后再试。",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "前往系统设置", style: .default) { _ in
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    })
                    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                    let scene = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first { $0.activationState == .foregroundActive }
                    let topVC = scene?.keyWindow?.rootViewController?
                        .topMostPresented() ?? scene?.keyWindow?.rootViewController
                    topVC?.present(alert, animated: true)
                }
            }
            switch authorization {
            case .allowed:
                self.updateCommandStatus(action: action, status: .executing)
                let queue = action == "audioLevel" ? DispatchQueue.main : DispatchQueue.global(qos: .userInitiated)
                queue.async {
                    if action == "audioLevel", !isAudioStop,
                       self.audioGeneration() != audioGenerationAtRequest {
                        completion(Self.authorizationError(capability: .microphone, status: .denied,
                                                           message: "麦克风请求已取消"), callbackId)
                        return
                    }
                    handler.handle(body: body) { [weak self] result in
                        self?.updateCommandStatus(action: action, status: .succeeded, result: result)
                        completion(result, callbackId)
                    }
                }
            case .denied(let result):
                self.updateCommandStatus(action: action, status: .failed, error: result["error"] as? String)
                completion(result, callbackId)
            }
        }
    }

    /// Internal so the test target can exercise managed page identity without
    /// a live WKWebView; behavior is identical to production callers.
    func effectiveManagedDocumentURL(_ current: URL?) -> URL? {
        guard let current, current.isFileURL else { return current }
        guard let appID = managedAppID, let manifest = trustRegistry.manifest(for: appID) else { return nil }
        if let mapped = offlinePackageLocator.logicalDocumentURL(for: current, parent: manifest, launchPage: managedLaunchPageURL) {
            return mapped
        }
        // Offline fallback: when the device has no network and the installed
        // stale package re-proves itself against its persisted signed parent
        // manifest, keep granting it page identity so bridge capability
        // declarations and grants stay consistent with the strong launch.
        guard let isOfflineProvider, isOfflineProvider(),
              offlineFallbackSignatureVerifier != nil else { return nil }
        return offlinePackageLocator.logicalDocumentURL(
            for: current,
            parent: manifest,
            launchPage: managedLaunchPageURL,
            offlineFallback: true,
            signatureVerifier: offlineFallbackSignatureVerifier
        )
    }

    /// Reports only the current document's signed declarations and grants.
    /// This is a snapshot, not a promise that a later action will succeed.
    private func capabilitySnapshot() -> [String: Any] {
        let documentURL = effectiveManagedDocumentURL(webView?.url ?? managedDocumentURL)
        let origin = documentURL.flatMap { HTMLAppOrigin.canonicalOrigin(forDocumentURL: $0) }
        let manifest = managedAppID.flatMap { trustRegistry.manifest(for: $0) }
        let subject = managedAppID.flatMap { id in origin.flatMap { permissionSubject(appID: id, origin: $0) } }
        let pageAllowed = documentURL.map { manifest?.allows(documentURL: $0) == true } ?? false
        var actions: [String: Any] = [:]
        for action in HTMLAppControlledAction.allCases {
            let supported = WebBridgeHostCapabilityPolicy.nativeActionAllowlist?.contains(action.rawValue) ?? true
            let declaration = origin.flatMap { manifest?.declaration(for: action, origin: $0) }
            let declared = pageAllowed && declaration != nil && subject != nil
            let requiresGrant = HTMLAppBridgeCapabilityPolicy.isGrantBasedAction(action)
            var appPermission = requiresGrant ? "notDetermined" : "notRequired"
            var systemPermission = "notRequired"
            var scope: String?
            if declared && supported && requiresGrant, let declaration, let subject {
                let capability = HTMLAppBridgeCapabilityPolicy.capability(for: action)
                if let grant = permissionLedger.grant(for: subject, capability: capability, actionIdentity: declaration.purposeId),
                   grant.scope == .always {
                    appPermission = "granted"
                    scope = grant.scope.rawValue
                }
                if action == .getLocation || action == .audioLevel {
                    systemPermission = nativeAuthorizationProvider.authorizationStatus(for: capability).rawValue
                }
            } else if !declared || !supported {
                appPermission = "unavailable"
                systemPermission = "unavailable"
            }
            var info: [String: Any] = ["supported": supported, "declared": declared, "appPermission": appPermission,
                                       "systemPermission": systemPermission, "requiresUserGesture": true]
            if let scope { info["grantScope"] = scope }
            actions[action.rawValue] = info
        }
        return ["schemaVersion": "1", "actions": actions]
    }

    private enum AuthorizationDecision {
        case allowed
        case denied([String: Any])
    }

    private func authorizeIfNeeded(
        action: String,
        body: [String: Any],
        completion: @escaping (AuthorizationDecision) -> Void
    ) {
        guard let capability = HTMLAppBridgeCapabilityPolicy.capability(for: action, body: body) else {
            completion(.allowed)
            return
        }
        WBKGateTrace.log("policy cap=\(capability.rawValue) managedAppID=\(managedAppID ?? "nil")")
        let currentURL = webView?.url ?? managedDocumentURL
        let liveURL = effectiveManagedDocumentURL(currentURL)
        // 分层信任模型：
        // 层级 3（网关注册应用）：managedAppID + 签名 manifest → 完整判定链
        // 层级 2（本地信任）：无网关注册 → origin 即身份 → 跳过 manifest 校验，
        //                     直接走授权面板（和浏览器权限弹窗同语义）
        let documentURL = liveURL
        guard let documentURL, let origin = HTMLAppOrigin.canonicalOrigin(forDocumentURL: documentURL) else {
            completion(.denied(Self.authorizationError(
                capability: capability,
                status: .denied,
                message: "无法识别页面来源，不能调用受保护的原生能力"
            )))
            return
        }

        // V2 actions are signed declarations and foreground gestures. Low
        // impact actions do not create reusable privacy grants; grant-based
        // actions continue through the grant gateway below. The gesture gate
        // applies to both classes so a programmatic call can never summon a
        // consent panel.
        if let controlledAction = HTMLAppBridgeCapabilityPolicy.controlledAction(for: action) {
            let capability = HTMLAppBridgeCapabilityPolicy.capability(for: controlledAction)
            let hasTrustedGesture = userGestureValidationOverride?() ??
                (UIApplication.shared.applicationState == .active && userGestureRecognizer?.consumeRecentUserGesture() == true)
            guard hasTrustedGesture else {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "请在应用前台通过页面交互发起此操作"
                )))
                return
            }
            guard let registeredAppID = managedAppID,
                  trustRegistry.manifest(for: registeredAppID)?
                      .declaration(for: controlledAction, origin: origin) != nil else {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "应用未在签名 Manifest 中声明此操作"
                )))
                return
            }
            if !HTMLAppBridgeCapabilityPolicy.isGrantBasedAction(controlledAction) {
                completion(.allowed)
                return
            }
        }

        let appID: String
        if let registered = managedAppID, trustRegistry.manifest(for: registered) != nil {
            appID = registered
        } else if let declared = declaredIdentity {
            // 页面 meta 声明身份（webbridgekit-app-id）：账本 key 升级为
            // page.{声明ID}，同 origin 下多应用授权隔离；origin 仍是四元组
            // 的一部分，跨 origin 无法冒领。"page." 前缀防止与网关注册的
            // 真实 appID 冲突。
            guard webView?.url == nil
                || liveURL == nil
                || HTMLAppOrigin.canonicalOrigin(forDocumentURL: liveURL!) == origin else {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "页面声明身份与当前来源不一致"
                )))
                return
            }
            if !declared.capabilities.isEmpty && !declared.capabilities.contains(capability) {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "页面未声明需要「\(capability.displayName)」能力（webbridgekit-capabilities）"
                )))
                return
            }
            appID = declared.namespacedAppID
        } else {
            // 本地信任：origin 即身份，无需网关注册
            appID = "local.\(origin)"
        }
        // 本地信任不依赖网关身份——直接用 local/page-appID 构造 subject
        let subject: HTMLAppPermissionSubject
        if appID.hasPrefix("local.") || appID.hasPrefix("page.") {
            subject = HTMLAppPermissionSubject(
                gatewayIdentity: "local-trust",
                appID: appID,
                origin: origin
            )
        } else if let registered = permissionSubject(appID: appID, origin: origin) {
            subject = registered
        } else {
            completion(.denied(Self.authorizationError(
                capability: capability,
                status: .denied,
                message: "未配置可信网关，不能调用受保护的原生能力"
            )))
            return
        }
        let params = body["params"] as? [String: Any] ?? body
        let requestID = UUID().uuidString
        let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let managedDeclaration: HTMLAppActionDeclaration?
        if let controlledAction = HTMLAppBridgeCapabilityPolicy.controlledAction(for: action),
           let registeredAppID = managedAppID {
            managedDeclaration = trustRegistry.manifest(for: registeredAppID)?
                .declaration(for: controlledAction, origin: origin)
        } else {
            managedDeclaration = nil
        }
        let request = HTMLAppCapabilityRequest(
            id: requestID,
            capability: capability,
            reason: reason?.isEmpty == false ? reason! : "使用\(capability.displayName)完成当前操作",
            scope: .once,
            purposeId: managedDeclaration?.purposeId
        )
        // page.*（meta 声明身份）与 local.* 同属本地信任层：
        // 不依赖网关注册，直接走系统层检查 + 账本 + 品牌面板
        let isLocalTrust = appID.hasPrefix("local.") || appID.hasPrefix("page.")
        if isLocalTrust {
            // 防重入：同 (subject, capability) 已有 pending 授权时拒绝新请求
            // （真机实测：JS 在面板等待期间可能重发 camera 调用，导致面板/系统弹窗循环）
            if hasPendingAuthorization(subject: subject, capability: capability) {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "授权正在进行中，请先完成当前授权"
                )))
                return
            }
            // 本地信任：先检查系统层（拒绝时直接弹引导，同网关路径）
            let nativeStatus = HTMLAppRuntimeCenter.shared.systemPermissionAdapter
                .authorizationStatus(for: capability)
            if nativeStatus == .denied || nativeStatus == .restricted {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("pwa.consent.systemResult"),
                        object: nil,
                        userInfo: ["granted": false]
                    )
                }
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .requiresSettings,
                    message: "iOS 系统权限已关闭，请前往系统设置开启"
                )))
                return
            }
            // 本地信任：跳过 gateway 的 manifest 校验，直接查账本
            if let grant = HTMLAppPermissionLedger.shared.grant(for: subject, capability: capability) {
                WBKGateTrace.log("LEDGER-HIT scope=\(grant.scope.rawValue) appID=\(appID)")
                completion(.allowed)
                return
            }
            WBKGateTrace.log("no-grant → panel appID=\(appID)")
            // 未授权：弹品牌半弹窗（topViewController 修复后 presenter 队列
            // 在 immersive 模式下也能正确定位——不再降级为 UIAlertController）
            guard let presenter = permissionConsentPresenter else {
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "无法显示授权确认"
                )))
                return
            }
            storePendingAuthorization(PendingAuthorization(
                subject: subject,
                documentURL: documentURL,
                request: request,
                completion: completion
            ))
            presenter.requestConsent(HTMLAppPermissionConsentRequest(
                application: .init(
                    id: appID,
                    name: declaredIdentity?.appName ?? URL(string: origin)?.host ?? origin
                ),
                requestID: request.id,
                origin: origin,
                capability: capability,
                reason: request.reason
            )) { [weak self] selectedScope in
                self?.finishPendingAuthorization(requestID: request.id, selectedScope: selectedScope)
            }
            return
        }

        let result = capabilityGateway.requestAuthorization(subject: subject, documentURL: documentURL, request: request)
        switch (result.status, result.authorizationLayer) {
        case (.granted, _), (.notDetermined, .nativeSystem):
            completion(.allowed)
        case (.notDetermined, .htmlApp):
            guard let presenter = permissionConsentPresenter else {
                capabilityGateway.cancelPendingRequests(subject: subject)
                completion(.denied(Self.authorizationError(
                    capability: capability,
                    status: .denied,
                    message: "无法显示 PWA 权限确认"
                )))
                return
            }
            storePendingAuthorization(PendingAuthorization(
                subject: subject,
                documentURL: documentURL,
                request: request,
                completion: completion
            ))
            presenter.requestConsent(HTMLAppPermissionConsentRequest(
                application: .init(
                    id: appID,
                    name: declaredIdentity?.appName ?? URL(string: origin)?.host ?? origin
                ),
                requestID: request.id,
                origin: origin,
                capability: capability,
                reason: request.reason
            )) { [weak self] selectedScope in
                self?.finishPendingAuthorization(requestID: request.id, selectedScope: selectedScope)
            }
        default:
            completion(.denied(Self.authorizationError(
                capability: capability,
                status: result.status,
                message: result.status == .requiresSettings
                    ? "iOS 系统权限已关闭，请前往系统设置开启"
                    : "PWA 未获得该原生能力授权"
            )))
        }
    }

    private func hasPendingAuthorization(subject: HTMLAppPermissionSubject, capability: HTMLAppCapability) -> Bool {
        pendingAuthorizationsLock.lock()
        defer { pendingAuthorizationsLock.unlock() }
        return pendingAuthorizations.values.contains { pending in
            pending.subject == subject && pending.request.capability == capability
        }
    }

    private func storePendingAuthorization(_ pending: PendingAuthorization) {
        pendingAuthorizationsLock.lock()
        pendingAuthorizations[pending.request.id] = pending
        pendingAuthorizationsLock.unlock()
    }

    private func takePendingAuthorization(requestID: String) -> PendingAuthorization? {
        pendingAuthorizationsLock.lock()
        let pending = pendingAuthorizations.removeValue(forKey: requestID)
        pendingAuthorizationsLock.unlock()
        return pending
    }

    private func finishPendingAuthorization(
        requestID: String,
        selectedScope: HTMLAppPermissionScope?
    ) {
        guard let pending = takePendingAuthorization(requestID: requestID) else { return }
        guard let selectedScope else {
            capabilityGateway.cancelPendingRequests(subject: pending.subject)
            pending.completion(.denied(Self.authorizationError(
                capability: pending.request.capability,
                status: .denied,
                message: "用户已取消授权"
            )))
            return
        }

        let selectedRequest = HTMLAppCapabilityRequest(
            id: pending.request.id,
            capability: pending.request.capability,
            reason: pending.request.reason,
            scope: selectedScope,
            purposeId: pending.request.purposeId
        )

        // 本地信任：跳过 gateway（无 manifest），请求系统权限 + 落账本
        if pending.subject.appID.hasPrefix("local.") || pending.subject.appID.hasPrefix("page.") {
            HTMLAppRuntimeCenter.shared.systemPermissionAdapter.requestAuthorization(
                for: selectedRequest.capability
            ) { systemStatus in
                let granted = systemStatus == .granted
                if granted {
                    _ = HTMLAppPermissionLedger.shared.grant(
                        subject: pending.subject,
                        capability: selectedRequest.capability,
                        scope: selectedScope
                    )
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .init("pwa.consent.systemResult"),
                        object: nil,
                        userInfo: ["granted": granted]
                    )
                }
                // 延迟一拍让面板 dismiss 动画完成，否则 handler 的
                // present (UIImagePickerController) 会与面板 dismiss 冲突
                // （真机卡死：相机出来→消失→面板又弹→点不动）
                if granted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        pending.completion(.allowed)
                    }
                } else {
                    pending.completion(.denied(Self.authorizationError(
                        capability: pending.request.capability,
                        status: .requiresSettings,
                        message: "iOS 系统权限已关闭，请前往系统设置开启"
                    )))
                }
            }
            return
        }

        capabilityGateway.resolveUserConsent(
            subject: pending.subject,
            documentURL: pending.documentURL,
            request: selectedRequest,
            approvedScope: selectedScope,
            granted: true
        ) { resolved in
            DispatchQueue.main.async {
                // 面板保持到了系统弹窗——现在按结果收起或切引导态
                NotificationCenter.default.post(
                    name: .init("pwa.consent.systemResult"),
                    object: nil,
                    userInfo: ["granted": resolved.status == .granted]
                )
            }
            if resolved.status == .granted {
                pending.completion(.allowed)
            } else {
                pending.completion(.denied(Self.authorizationError(
                    capability: pending.request.capability,
                    status: resolved.status,
                    message: resolved.status == .requiresSettings
                        ? "iOS 系统权限已关闭，请前往系统设置开启"
                        : "原生能力授权失败"
                )))
            }
        }
    }

    private func cancelPendingAuthorizations(appID: String) {
        pendingAuthorizationsLock.lock()
        let cancelled = pendingAuthorizations.values.filter { $0.subject.appID == appID }
        cancelled.forEach { pendingAuthorizations.removeValue(forKey: $0.request.id) }
        pendingAuthorizationsLock.unlock()

        cancelled.forEach { pending in
            capabilityGateway.cancelPendingRequests(subject: pending.subject)
            permissionConsentPresenter?.cancelConsent(
                appID: pending.subject.appID,
                requestID: pending.request.id
            )
            pending.completion(.denied(Self.authorizationError(
                capability: pending.request.capability,
                status: .denied,
                message: "PWA 已关闭或页面来源已变更"
            )))
        }
    }

    private static func authorizationError(
        capability: HTMLAppCapability,
        status: HTMLAppCapabilityResult.Status,
        message: String
    ) -> [String: Any] {
        [
            "success": false,
            "error": message,
            "code": "PWA_CAPABILITY_DENIED",
            "capability": capability.rawValue,
            "status": status.rawValue
        ]
    }

    private func permissionSubject(appID: String, origin: String) -> HTMLAppPermissionSubject? {
        let activeGatewayIdentity = gatewayIdentity ?? HTMLAppRuntimeCenter.shared.gatewayIdentity
        guard !activeGatewayIdentity.isEmpty else { return nil }
        return HTMLAppPermissionSubject(
            gatewayIdentity: activeGatewayIdentity,
            appID: appID,
            origin: origin
        )
    }

    // MARK: - Register Handlers

    /// 注册 Handler 工厂方法（懒加载优化）
    /// 只注册工厂方法，不立即创建 Handler 实例
    private func registerHandlerFactories() {
        // 基础功能
        handlerFactories["share"] = { WebShareHandler() }
        handlerFactories["addToHomeScreen"] = { WebAddToHomeScreenHandler() }
        handlerFactories["getLocation"] = { WebLocationHandler() }
        handlerFactories["requestPermission"] = { WebPermissionHandler() }

        // 系统信息
        handlerFactories["getSystemInfo"] = { WebSystemInfoHandler() }
        handlerFactories["getNetworkInfo"] = { WebNetworkHandler() }

        // 交互反馈
        handlerFactories["haptic"] = { WebHapticHandler() }
        handlerFactories["vibrate"] = { WebVibrateHandler() }
        handlerFactories["fullscreen"] = { WebFullscreenHandler() }

        // 剪贴板
        handlerFactories["clipboard"] = { WebClipboardHandler() }

        // 扫码
        handlerFactories["scan"] = { WebScanHandler() }

        // 相机
        handlerFactories["camera"] = { WebCameraHandler() }

        // 视频流
        handlerFactories["videoStream"] = { WebVideoHandler() }

        // 语音识别
        handlerFactories["speech"] = { WebSpeechHandler() }

        // 实时音频音量监控
        handlerFactories["audioLevel"] = { WebAudioLevelHandler() }

        // 通讯录
        handlerFactories["contacts"] = { WebContactsHandler() }

        // 屏幕控制
        handlerFactories["screen"] = { WebScreenHandler() }

        // 布局控制
        handlerFactories["layout"] = { WebLayoutHandler() }

        // 投屏控制
        handlerFactories["mirroring"] = { WebMirroringHandler() }

        // 传感器控制
        handlerFactories["sensors"] = { WebSensorsHandler() }

        // 媒体与文件
        handlerFactories["media"] = { WebMediaHandler() }

        // 系统增强
        handlerFactories["systemExtra"] = { WebSystemExtraHandler() }

        // 语音合成
        handlerFactories["tts"] = { WebSpeechSynthesisHandler() }

        // 蓝牙控制
        handlerFactories["bluetooth"] = { WebBluetoothHandler() }

        // 文件选择
        handlerFactories["file"] = { WebFileHandler() }

        // 相册选择 (iOS 14+)
        if #available(iOS 14, *) {
            handlerFactories["photo"] = { WebPhotoHandler() }
        }

        // 权限状态查询
        handlerFactories["getPermissionStatus"] = { WebPermissionStatusHandler() }

        // 打开系统设置
        handlerFactories["openSettings"] = { WebOpenSettingsHandler() }

        // 打开本地页面
        handlerFactories["openPage"] = { WebOpenPageHandler() }

        // 关闭当前页面
        handlerFactories["closePage"] = { WebClosePageHandler() }

        // 获取导航历史
        handlerFactories["getHistory"] = { WebGetHistoryHandler() }

        // 获取透传参数
        handlerFactories["getPayload"] = { WebPayloadHandler() }

        // 后退
        handlerFactories["goBack"] = { WebGoBackHandler() }

        // 设置弹窗参数
        handlerFactories["setModal"] = { WebSetModalHandler() }

        // 手势监控
        handlerFactories["gesture"] = { WebGestureHandler() }

        // 缓存调试
        handlerFactories["cacheDebug"] = { WebCacheDebugHandler() }

        // 页面缓存管理
        handlerFactories["page"] = { WebPageCacheHandler() }

        // 本地通知（非 APNs）
        handlerFactories["showNotification"] = { WebShowNotificationHandler() }

        StructuredLogger.shared.debug("[BRIDGE] [JS Bridge] 已注册 \(handlerFactories.count) 个 Handler 工厂（懒加载模式）", category: .handler)
        StructuredLogger.shared.debug("   工厂列表: \(Array(handlerFactories.keys).sorted())", category: .handler)
    }

    // MARK: - Get Handler (Lazy Loading)

    /// 获取 Handler 实例（懒加载）
    /// 如果实例已存在，直接返回；否则通过工厂方法创建
    /// - Parameter action: Handler 对应的 action 名称
    /// - Returns: Handler 实例，如果不存在则返回 nil
    public func getHandler(for action: String) -> WebNativeAPI? {
        handlersLock.lock()
        defer { handlersLock.unlock() }

        // 如果已创建，直接返回
        if let handler = nativeHandlers[action] {
            return handler
        }

        // 如果未创建，通过工厂方法创建
        guard let factory = handlerFactories[action] else {
            return nil
        }

        // 创建 Handler 实例
        let handler = factory()
        nativeHandlers[action] = handler

        // 设置 WebView 引用
        if let baseHandler = handler as? BaseWebNativeHandler {
            if let webView = self.webView {
                baseHandler.webView = webView
            } else {
            }
        }

        StructuredLogger.shared.debug("[RECYCLE] [JS Bridge] 懒加载创建 Handler: \(action)", category: .handler)
        return handler
    }

    // MARK: - Send Result to JS

    public func sendResultToJS(_ result: Any, callbackId: String?) {
        var resultDict: [String: Any] = [:]

        // 处理不同的结果类型
        if let response = result as? WebBridgeResponse {
            // 如果是统一响应模型，转换为字典
            resultDict = response.toDictionary()
        } else if let dict = result as? [String: Any] {
            // 如果已经是字典，直接使用
            resultDict = dict
        } else {
            // 否则包装成 data 字段
            resultDict = ["data": result]
        }

        // 设置 callbackId（关键！）
        if let callbackId = callbackId {
            resultDict["callbackId"] = callbackId
            resultDict["messageId"] = callbackId
        } else {
        }

        let script: String
        if let jsonString = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonStr = String(data: jsonString, encoding: .utf8) {
            // 记录发送到 JS 的数据
            WebBridgeLogger.shared.log(.info, "[JS Bridge] Sending to JS: \(jsonStr.prefix(200))")
            script = "window.BarkBridge.receiveResult(\(jsonStr));"
        } else {
            // 如果 JSON 序列化失败，使用简单的字符串
            script = "window.BarkBridge.receiveResult({'success': false, 'error': 'JSON serialization failed'});"
        }

        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else {
                WebBridgeLogger.shared.error("[JS Bridge] Failed to send result: webView is nil")
                return
            }
            webView.evaluateJavaScript(script, completionHandler: { _, error in
                if let error = error {
                    WebBridgeLogger.shared.error("JavaScript execution failed: \(error.localizedDescription)")
                }
            })
        }
    }

    public func sendErrorToJS(_ error: String, callbackId: String?) {
        let result: [String: Any] = ["success": false, "error": error]
        sendResultToJS(result, callbackId: callbackId)
    }

    // MARK: - Send Event to JS

    /**
     * 向 JS 发送主动推送事件（自动记录日志）
     * @param event 事件名称
     * @param data 事件携带的数据
     */
    public func sendEventToJS(event: String, data: Any) {
        // 自动记录事件日志
        WebBridgeLogger.shared.logEvent(event: event, data: data, module: "JSBridge")

        let script: String
        let resultDict: [String: Any] = ["event": event, "data": data]

        if let jsonString = try? JSONSerialization.data(withJSONObject: resultDict, options: []),
           let jsonString = String(data: jsonString, encoding: .utf8) {
            script = "window.BarkBridge.receiveEvent('\(event)', \(jsonString).data);"
        } else {
            // 如果 JSON 序列化失败，直接传递原始值（如果是简单类型）
            if let strData = data as? String {
                script = "window.BarkBridge.receiveEvent('\(event)', '\(strData)');"
            } else {
                script = "window.BarkBridge.receiveEvent('\(event)', \(data));"
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: { _, error in
                if let error = error {
                    WebBridgeLogger.shared.error("Event delivery failed: \(error.localizedDescription)")
                }
            })
        }
    }

    // MARK: - Set WebView

    public func setWebView(_ webView: WKWebView) {
        self.webView = webView
        if let userGestureRecognizer {
            webView.removeGestureRecognizer(userGestureRecognizer)
        }
        let gestureRecognizer = WBKUserGestureRecognizer()
        gestureRecognizer.cancelsTouchesInView = false
        gestureRecognizer.delaysTouchesBegan = false
        gestureRecognizer.delaysTouchesEnded = false
        webView.addGestureRecognizer(gestureRecognizer)
        userGestureRecognizer = gestureRecognizer
        // 为已创建的 Handler 设置 webView（懒加载模式下，Handler 在 getHandler 时自动设置）
        handlersLock.lock()
        let createdHandlers = Array(nativeHandlers.values)
        handlersLock.unlock()

        for handler in createdHandlers {
            if let baseHandler = handler as? BaseWebNativeHandler {
                baseHandler.webView = webView
            }
        }

        StructuredLogger.shared.debug("[LINK] [JS Bridge] WebView 已设置，已创建 \(createdHandlers.count) 个 Handler", category: .handler)
    }

    // MARK: - Command Trace History Management

    /// 添加命令到历史记录
    /// - Parameter trace: 命令跟踪条目
    private func addCommandToHistory(_ trace: CommandTraceEntry) {
        historyLock.lock()
        defer { historyLock.unlock() }

        commandHistory.append(trace)

        // 限制历史记录大小（FIFO）
        if commandHistory.count > maxHistorySize {
            commandHistory.removeFirst()
        }

        NSLog("[NOTE] [JS Bridge] Added command to history: \(trace.action) (total: \(commandHistory.count))")
    }

    /// 更新命令状态
    /// - Parameters:
    ///   - action: 命令名称
    ///   - status: 新状态
    ///   - result: 成功结果（可选）
    ///   - error: 错误信息（可选）
    private func updateCommandStatus(action: String, status: CommandTraceEntry.Status, result: Any? = nil, error: String? = nil) {
        historyLock.lock()
        defer { historyLock.unlock() }

        // 查找并更新最新的同名命令
        if let index = commandHistory.lastIndex(where: { $0.action == action }) {
            var entry = commandHistory[index]
            entry.status = status
            entry.result = result
            entry.error = error
            entry.completedAt = status == .received ? nil : Date()
            commandHistory[index] = entry

            let logMessage: String
            switch status {
            case .succeeded:
                logMessage = "[OK] Command succeeded: \(action)"
            case .failed:
                logMessage = "[FAIL] Command failed: \(action) - \(error ?? "Unknown error")"
            case .executing:
                logMessage = "⏳ Command executing: \(action)"
            case .received:
                logMessage = "[RECV] Command received: \(action)"
            }

            NSLog(logMessage)
        }
    }

    /// 获取最近的命令历史记录
    /// - Parameter limit: 最大返回数量（默认 20）
    /// - Returns: 命令跟踪条目数组
    public func getCommandHistory(limit: Int = 20) -> [CommandTraceEntry] {
        historyLock.lock()
        defer { historyLock.unlock() }

        let count = min(limit, commandHistory.count)
        return Array(commandHistory.suffix(count))
    }

    /// 清空命令历史记录
    public func clearCommandHistory() {
        historyLock.lock()
        defer { historyLock.unlock() }

        commandHistory.removeAll()
        NSLog("[DEL] [JS Bridge] Cleared command history")
    }

    /// 按操作名称筛选命令历史
    /// - Parameter action: 操作名称
    /// - Returns: 匹配的命令历史记录
    public func getCommandsByAction(_ action: String) -> [CommandTraceEntry] {
        historyLock.lock()
        defer { historyLock.unlock() }

        return commandHistory.filter { $0.action == action }
    }
}

// MARK: - Command Trace Entry

/// 命令跟踪条目（用于调试和历史记录）
public struct CommandTraceEntry {
    /// 操作名称
    public let action: String

    /// 输入参数
    public let input: [String: Any]

    /// 时间戳
    public let timestamp: Date

    /// 回调 ID
    public let callbackId: String?

    /// 状态
    public var status: Status

    /// 执行结果
    public var result: Any?

    /// 错误信息
    public var error: String?

    /// 完成时间
    public var completedAt: Date?

    /// 命令执行状态
    public enum Status {
        case received      // 已接收
        case executing    // 执行中
        case succeeded    // 成功
        case failed       // 失败
    }

    /// 创建跟踪条目
    public init(action: String, input: [String: Any], timestamp: Date, callbackId: String?, status: Status) {
        self.action = action
        self.input = input
        self.timestamp = timestamp
        self.callbackId = callbackId
        self.status = status
        self.result = nil
        self.error = nil
        self.completedAt = nil
    }
}

private extension UIViewController {
    func topMostPresented() -> UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

/// 权限判定链 trace。Debug 构建写宿主 /tmp 供模拟器排障；Release 保留
/// 无操作实现，让同一套授权路径能安全地通过归档编译。
enum WBKGateTrace {
    static func log(_ line: String) {
        #if DEBUG
        let path = "/tmp/wbk-gate-trace.log"
        let stamped = "\(Date().timeIntervalSince1970) [WBKGate] \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
