//
//  WebJavaScriptBridgeTests.swift
//  CoreTests
//

import XCTest
@testable import WebBridgeKit

final class WebJavaScriptBridgeTests: XCTestCase {

    private final class MemoryStorage: HTMLAppRuntimeStorage {
        private var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data?, forKey key: String) { values[key] = data }
    }

    private final class NativeAuthorizationProvider: HTMLAppNativeAuthorizationProviding {
        var status: HTMLAppCapabilityResult.Status = .granted
        func authorizationStatus(for capability: HTMLAppCapability) -> HTMLAppCapabilityResult.Status { status }
        func requestAuthorization(
            for capability: HTMLAppCapability,
            completion: @escaping (HTMLAppCapabilityResult.Status) -> Void
        ) {
            completion(status)
        }
    }

    private final class ConsentPresenter: HTMLAppPermissionConsentPresenting {
        var selectedScope: HTMLAppPermissionScope?
        var requestCount = 0
        var requestedAppIDs: [String] = []
        var pending: [String: (HTMLAppPermissionScope?) -> Void] = [:]
        var completesImmediately = true
        func requestConsent(
            _ request: HTMLAppPermissionConsentRequest,
            completion: @escaping (HTMLAppPermissionScope?) -> Void
        ) {
            requestCount += 1
            requestedAppIDs.append(request.application.id)
            if completesImmediately {
                completion(selectedScope)
            } else {
                pending[request.requestID] = completion
            }
        }

        func cancelConsent(appID: String, requestID: String) {
            pending.removeValue(forKey: requestID)?(nil)
        }
    }

    private final class ShareResultStub: WebNativeAPI {
        func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
            completion(["success": true])
        }
    }

    private final class CallCountingStub: WebNativeAPI {
        var callCount = 0
        func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
            callCount += 1
            completion(["success": true])
        }
    }

    private final class RevocationAwareHandler: WebNativeAPI, HTMLAppCapabilityRevocationHandling {
        let revoked: XCTestExpectation

        init(revoked: XCTestExpectation) {
            self.revoked = revoked
        }

        func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
            completion(["success": true])
        }

        func htmlAppCapabilityDidRevoke() {
            revoked.fulfill()
        }
    }

    private var bridge: WebJavaScriptBridge!

    private func registerV2Manifest(
        in registry: HTMLAppTrustRegistry,
        action: HTMLAppControlledAction = .share,
        origins: [String] = ["https://bridge.example.com"],
        scope: HTMLAppPermissionScope = .appSession
    ) throws -> HTMLAppManifest {
        let manifest = HTMLAppManifest(
            appID: "com.example.v2",
            name: "V2 Demo",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.share],
            capabilitiesV2: [
                HTMLAppActionDeclaration(
                    action: action,
                    origins: origins,
                    purposeId: "v2-purpose",
                    purpose: "Share the selected report",
                    scope: scope
                )
            ],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(manifest)
        return manifest
    }

    override func setUp() {
        super.setUp()
        bridge = WebJavaScriptBridge()
    }

    override func tearDown() {
        bridge = nil
        super.tearDown()
    }

    // MARK: - Initialization

    func testInitializationRegistersHandlerFactories() {
        XCTAssertTrue(bridge.nativeHandlers.isEmpty, "Handlers should be lazy-loaded and empty after initialization")
        XCTAssertNotNil(bridge.getHandler(for: "share"), "Factory should create handler for known action")
    }

    func testGetHandlerReturnsHandlerForRegisteredAction() {
        let handler = bridge.getHandler(for: "share")
        XCTAssertNotNil(handler)
    }

    func testGetHandlerReturnsNilForUnknownAction() {
        let handler = bridge.getHandler(for: "nonexistent_action_xyz")
        XCTAssertNil(handler)
    }

    func testFullscreenFactoryIsRegistered() {
        XCTAssertTrue(bridge.getHandler(for: "fullscreen") is WebFullscreenHandler)
    }

    func testGetHandlerCreatesSameInstanceOnSecondCall() {
        let first = bridge.getHandler(for: "share")
        let second = bridge.getHandler(for: "share")
        XCTAssertTrue((first as AnyObject) === (second as AnyObject), "Lazy loading should return the same instance")
    }

    func testHostActionAllowlistRejectsUnlistedNativeActionBeforeHandler() {
        let previousAllowlist = WebBridgeHostCapabilityPolicy.nativeActionAllowlist
        WebBridgeHostCapabilityPolicy.nativeActionAllowlist = ["share", "haptic", "vibrate"]
        defer { WebBridgeHostCapabilityPolicy.nativeActionAllowlist = previousAllowlist }
        let cameraStub = CallCountingStub()
        bridge.nativeHandlers["camera"] = cameraStub

        let completed = expectation(description: "host policy blocks camera")
        bridge.handle(body: ["action": "camera", "callbackId": "host-policy-camera"]) { result, _ in
            let response = result as? WebBridgeResponse
            XCTAssertEqual(response?.errorCode, 403)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(cameraStub.callCount, 0)
    }

    func testGetHandlerForMultipleActions() {
        XCTAssertNotNil(bridge.getHandler(for: "getLocation"))
        XCTAssertNotNil(bridge.getHandler(for: "getSystemInfo"))
        XCTAssertNotNil(bridge.getHandler(for: "haptic"))
        XCTAssertNotNil(bridge.getHandler(for: "clipboard"))
    }

    func testManagedPWARevocationStopsActiveCapabilityHandler() {
        let ledger = HTMLAppPermissionLedger(storage: MemoryStorage())
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: HTMLAppTrustRegistry(storage: MemoryStorage()),
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let appID = "com.example.bridge"
        let origin = "https://bridge.example.com"
        managedBridge.configureManagedHTMLApp(
            appID: appID,
            documentURL: URL(string: "\(origin)/index.html")
        )
        let stopped = expectation(description: "active capability stopped")
        managedBridge.nativeHandlers["bluetooth"] = RevocationAwareHandler(revoked: stopped)
        ledger.grant(appID: appID, origin: origin, capability: .bluetooth, scope: .appSession)

        ledger.revoke(appID: appID, origin: origin, capability: .bluetooth)

        wait(for: [stopped], timeout: 1)
    }

    // MARK: - Send Error to JS

    func testSendErrorToJSDoesNotCrashWithoutWebView() {
        bridge.sendErrorToJS("test error", callbackId: "cb-1")
    }

    func testSendResultToJSWithDictionary() {
        let result: [String: Any] = ["success": true, "data": "test"]
        bridge.sendResultToJS(result, callbackId: "cb-2")
    }

    func testSendResultToJSWithNilCallbackId() {
        let result: [String: Any] = ["success": true]
        bridge.sendResultToJS(result, callbackId: nil)
    }

    // MARK: - Send Event to JS

    func testSendEventToJSDoesNotCrashWithoutWebView() {
        bridge.sendEventToJS(event: "testEvent", data: "testData")
    }

    func testSendEventToJSWithDictionaryData() {
        bridge.sendEventToJS(event: "pageLoaded", data: ["url": "https://example.com"])
    }

    // MARK: - setWebView

    func testSetWebViewDoesNotCrash() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        bridge.setWebView(webView)
    }

    // MARK: - Callback ID

    func testCurrentCallbackIdInitiallyNil() {
        XCTAssertNil(bridge.currentCallbackId)
    }

    func testProtectedActionIsDeniedForUnmanagedPage() {
        let completed = expectation(description: "bridge completion")
        bridge.handle(body: [
            "action": "clipboard",
            "callbackId": "unmanaged-1",
            "params": ["action": "read"]
        ]) { result, _ in
            let response = result as? [String: Any]
            XCTAssertEqual(response?["success"] as? Bool, false)
            XCTAssertEqual(response?["code"] as? String, "PWA_CAPABILITY_DENIED")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testControlledActionRequiresExactSignedDeclaration() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let legacyManifest = HTMLAppManifest(
            appID: "com.example.v2",
            name: "Legacy Only",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.share],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(legacyManifest)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: HTMLAppPermissionLedger(storage: storage),
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        managedBridge.configureManagedHTMLApp(
            appID: legacyManifest.appID,
            documentURL: URL(string: legacyManifest.startURL)
        )

        let completed = expectation(description: "legacy capability denied")
        managedBridge.handle(body: [
            "action": "share",
            "callbackId": "v2-missing",
            "params": ["text": "hello", "url": "https://example.com"]
        ]) { result, _ in
            let response = result as? [String: Any]
            XCTAssertEqual(response?["status"] as? String, "denied")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testDeclaredShareRunsAfterGestureWithoutReusableConsentGrant() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerV2Manifest(in: registry)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.userGestureValidationOverride = { true }
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        managedBridge.nativeHandlers["share"] = ShareResultStub()

        let completed = expectation(description: "v2 action allowed")
        managedBridge.handle(body: [
            "action": "share",
            "callbackId": "v2-share",
            "params": [
                "text": "runtime reason",
                "url": "https://example.com",
            ]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(presenter.requestCount, 0)
        let origin = try XCTUnwrap(HTMLAppOrigin.canonicalOrigin(forDocumentURL: URL(string: manifest.startURL)!))
        let subject = HTMLAppPermissionSubject(
            gatewayIdentity: "test-gateway",
            appID: manifest.appID,
            origin: origin
        )
        XCTAssertNil(ledger.grant(for: subject, capability: .share, actionIdentity: "v2-purpose"))
    }

    func testDeclaredFullscreenRunsAfterGestureWithoutPrivacyConsentOrReusableGrant() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerV2Manifest(in: registry, action: .fullscreen)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.userGestureValidationOverride = { true }
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )
        managedBridge.nativeHandlers["fullscreen"] = ShareResultStub()

        let completed = expectation(description: "declared fullscreen action allowed")
        managedBridge.handle(body: [
            "action": "fullscreen",
            "callbackId": "v2-fullscreen",
            "params": ["enabled": true]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(presenter.requestCount, 0)
        let origin = try XCTUnwrap(HTMLAppOrigin.canonicalOrigin(forDocumentURL: URL(string: manifest.startURL)!))
        let subject = HTMLAppPermissionSubject(
            gatewayIdentity: "test-gateway",
            appID: manifest.appID,
            origin: origin
        )
        XCTAssertNil(ledger.grant(for: subject, capability: .displayStatus, actionIdentity: "v2-purpose"))
    }

    func testControlledActionNeedsForegroundUserGesture() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerV2Manifest(in: registry)
        let presenter = ConsentPresenter()
        presenter.selectedScope = .always
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: HTMLAppPermissionLedger(storage: storage),
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(appID: manifest.appID, documentURL: URL(string: manifest.startURL))

        let completed = expectation(description: "gestureless action denied")
        managedBridge.handle(body: ["action": "share", "callbackId": "no-gesture"]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["status"] as? String, "denied")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(presenter.requestCount, 0)
    }

    func testControlledActionsDoNotShareCapabilityGrantIdentity() throws {
        let ledger = HTMLAppPermissionLedger(storage: MemoryStorage())
        let subject = HTMLAppPermissionSubject(
            gatewayIdentity: "gateway-a",
            appID: "com.example.v2",
            origin: "https://bridge.example.com"
        )
        ledger.grant(subject: subject, capability: .displayStatus, scope: .always, actionIdentity: "haptic-purpose")

        XCTAssertNotNil(ledger.grant(for: subject, capability: .displayStatus, actionIdentity: "haptic-purpose"))
        XCTAssertNil(ledger.grant(for: subject, capability: .displayStatus, actionIdentity: "vibrate-purpose"))
        XCTAssertNil(ledger.grant(for: subject, capability: .displayStatus))
    }

    func testRemovingV2DeclarationPrunesActionGrantEvenWhenLegacyCapabilityRemains() throws {
        let ledger = HTMLAppPermissionLedger(storage: MemoryStorage())
        let origin = "https://bridge.example.com"
        let subject = HTMLAppPermissionSubject(gatewayIdentity: "gateway-a", appID: "com.example.v2", origin: origin)
        ledger.grant(subject: subject, capability: .share, scope: .always, actionIdentity: "v2-purpose")
        let updatedManifest = HTMLAppManifest(
            appID: "com.example.v2",
            name: "Updated",
            startURL: "\(origin)/index.html",
            allowedOrigins: [origin],
            capabilities: [.share],
            capabilitiesV2: [],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "2", persistent: false)
        )

        ledger.syncGrants(with: updatedManifest, gatewayIdentity: subject.gatewayIdentity, origin: origin)

        XCTAssertNil(ledger.grant(for: subject, capability: .share, actionIdentity: "v2-purpose"))
        XCTAssertTrue(ledger.grants(for: subject).isEmpty)
    }

    func testDeclaredClipboardUsesActionIdentityAndReusableGrant() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let manifest = try registerV2Manifest(
            in: registry,
            action: .clipboard,
            scope: .always
        )
        let presenter = ConsentPresenter()
        presenter.selectedScope = .always
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )
        managedBridge.nativeHandlers["clipboard"] = ShareResultStub()

        let first = expectation(description: "first clipboard request prompts")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "clipboard-1",
            "params": ["action": "read"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            first.fulfill()
        }
        wait(for: [first], timeout: 1)

        let second = expectation(description: "second clipboard request uses the grant")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "clipboard-2",
            "params": ["action": "read"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(presenter.requestCount, 1)

        let origin = try XCTUnwrap(HTMLAppOrigin.canonicalOrigin(forDocumentURL: URL(string: manifest.startURL)!))
        let subject = HTMLAppPermissionSubject(
            gatewayIdentity: "test-gateway",
            appID: manifest.appID,
            origin: origin
        )
        XCTAssertNotNil(ledger.grant(for: subject, capability: .clipboard, actionIdentity: "v2-purpose"))
    }

    func testLocationWithoutSignedDeclarationIsDeniedEvenWithLegacyCapability() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let manifest = HTMLAppManifest(
            appID: "com.example.v2",
            name: "Legacy location",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.location],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(manifest)
        let presenter = ConsentPresenter()
        presenter.selectedScope = .always
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )
        managedBridge.nativeHandlers["getLocation"] = ShareResultStub()

        let completed = expectation(description: "undeclared location denied")
        managedBridge.handle(body: [
            "action": "getLocation",
            "callbackId": "location-denied"
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["status"] as? String, "denied")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(presenter.requestCount, 0)
    }

    func testManagedPWAConsentCanBeCancelledBeforeHandlerRuns() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let manifest = HTMLAppManifest(
            appID: "com.example.bridge",
            name: "Bridge Demo",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.clipboard],
            capabilitiesV2: [Self.clipboardDeclaration],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(manifest)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        let completed = expectation(description: "bridge completion")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "managed-cancel-1",
            "params": ["action": "read", "reason": "Paste a reference number"]
        ]) { result, _ in
            let response = result as? [String: Any]
            XCTAssertEqual(response?["status"] as? String, "denied")
            XCTAssertEqual(presenter.requestCount, 1)
            XCTAssertTrue(ledger.grants(for: manifest.appID).isEmpty)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testManagedPWAAlwaysGrantPersistsAndSkipsRepeatedConsent() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let manifest = HTMLAppManifest(
            appID: "com.example.bridge",
            name: "Bridge Demo",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.clipboard],
            capabilitiesV2: [Self.clipboardDeclaration],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(manifest)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        presenter.selectedScope = .always
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        let first = expectation(description: "first bridge completion")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "managed-allow-1",
            "params": ["action": "read", "reason": "Paste a reference number"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            first.fulfill()
        }
        wait(for: [first], timeout: 1)

        let documentURL = try XCTUnwrap(URL(string: manifest.startURL))
        let origin = try XCTUnwrap(HTMLAppOrigin.canonicalOrigin(forDocumentURL: documentURL))
        XCTAssertEqual(ledger.grants(for: manifest.appID).first { $0.capability == .clipboard }?.scope, .always)

        let second = expectation(description: "second bridge completion")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "managed-allow-2",
            "params": ["action": "read"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(presenter.requestCount, 1)
        XCTAssertEqual(presenter.requestedAppIDs, [manifest.appID])
    }

    func testManagedPWACancelledConsentDoesNotLeaveGatewayRequestReusable() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerClipboardManifest(in: registry)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: HTMLAppPermissionLedger(storage: storage),
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        let cancelled = expectation(description: "cancelled request")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "same-js-callback",
            "params": ["action": "read"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["status"] as? String, "denied")
            cancelled.fulfill()
        }
        wait(for: [cancelled], timeout: 1)

        presenter.selectedScope = .always
        let allowed = expectation(description: "new request allowed")
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "same-js-callback",
            "params": ["action": "read"]
        ]) { result, _ in
            XCTAssertEqual((result as? [String: Any])?["success"] as? Bool, true)
            allowed.fulfill()
        }
        wait(for: [allowed], timeout: 1)
        XCTAssertEqual(presenter.requestCount, 2)
    }

    func testEndingManagedPWASessionCancelsPendingAuthorizationExactlyOnce() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerClipboardManifest(in: registry)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: HTMLAppPermissionLedger(storage: storage),
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        let presenter = ConsentPresenter()
        presenter.completesImmediately = false
        managedBridge.permissionConsentPresenter = presenter
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        let completed = expectation(description: "pending request cancelled")
        completed.expectedFulfillmentCount = 1
        var completionCount = 0
        managedBridge.handle(body: [
            "action": "clipboard",
            "callbackId": "pending-1",
            "params": ["action": "read"]
        ]) { result, _ in
            completionCount += 1
            XCTAssertEqual((result as? [String: Any])?["status"] as? String, "denied")
            completed.fulfill()
        }

        XCTAssertEqual(presenter.pending.count, 1)
        let lateCompletion = presenter.pending.values.first
        managedBridge.endManagedHTMLAppSession()
        lateCompletion?(.always)

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(presenter.pending.isEmpty)
    }

    func testEndingManagedPWASessionClearsOnlySessionGrantForCurrentOrigin() throws {
        let storage = MemoryStorage()
        let registry = HTMLAppTrustRegistry(storage: storage)
        let manifest = try registerClipboardManifest(in: registry)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let origin = "https://bridge.example.com"
        ledger.grant(appID: manifest.appID, origin: origin, capability: .clipboard, scope: .appSession)
        ledger.grant(appID: manifest.appID, origin: origin, capability: .camera, scope: .always)
        let managedBridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: NativeAuthorizationProvider()
        )
        managedBridge.configureManagedHTMLApp(
            appID: manifest.appID,
            documentURL: URL(string: manifest.startURL)
        )

        managedBridge.endManagedHTMLAppSession()

        XCTAssertNil(ledger.grant(
            for: manifest.appID,
            origin: origin,
            capability: .clipboard
        ))
        XCTAssertEqual(ledger.grant(
            for: manifest.appID,
            origin: origin,
            capability: .camera
        )?.scope, .always)
    }

    private func registerClipboardManifest(in registry: HTMLAppTrustRegistry) throws -> HTMLAppManifest {
        let manifest = HTMLAppManifest(
            appID: "com.example.bridge",
            name: "Bridge Demo",
            startURL: "https://bridge.example.com/index.html",
            allowedOrigins: ["https://bridge.example.com"],
            capabilities: [.clipboard, .camera],
            capabilitiesV2: [Self.clipboardDeclaration],
            routes: ["/index.html"],
            cache: HTMLAppCachePolicy(strategy: .networkOnly, version: "1", persistent: false)
        )
        try registry.register(manifest)
        return manifest
    }

    private static let clipboardDeclaration = HTMLAppActionDeclaration(
        action: .clipboard,
        origins: ["https://bridge.example.com"],
        purposeId: "bridge-clipboard",
        purpose: "Read and write clipboard values for the demo",
        scope: .always
    )
}

import WebKit
