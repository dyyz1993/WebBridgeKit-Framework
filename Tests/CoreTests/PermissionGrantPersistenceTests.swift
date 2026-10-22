//
//  PermissionGrantPersistenceTests.swift
//  CoreTests
//
//  授权持久化的核心回归（2026-10-22 用户实测 bug）：
//  用户在面板选「始终允许」后，下次调用必须免询问放行 —— 即使签名声明的
//  scope 不是 .always。
//
//  此前 HTMLAppRuntime.requestAuthorization 的免询问分支要求
//  grant.scope == declaration?.scope，不匹配时撤销授权并返回 denied。
//  真机上 action-demo 的定位声明确非 .always，于是用户选的「始终允许」
//  被判不匹配并立刻撤销 → 表现为杀掉 App 重开授权丢失、仍弹面板。
//

import XCTest
@testable import WebBridgeKit

final class PermissionGrantPersistenceTests: XCTestCase {

    private final class MemoryStorage: HTMLAppRuntimeStorage {
        private var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data?, forKey key: String) { values[key] = data }
    }

    private final class GrantedProvider: HTMLAppNativeAuthorizationProviding {
        func authorizationStatus(for capability: HTMLAppCapability) -> HTMLAppCapabilityResult.Status { .granted }
        func requestAuthorization(
            for capability: HTMLAppCapability,
            completion: @escaping (HTMLAppCapabilityResult.Status) -> Void
        ) {
            completion(.granted)
        }
    }

    private let origin = "https://drel.app"
    private let appID = "dev.drel.action-demo"
    private let documentURL = URL(string: "https://drel.app/test/actions/v1/index.html")!

    private func makeManifest(scope: HTMLAppPermissionScope) -> HTMLAppManifest {
        HTMLAppManifest(
            appID: appID,
            name: "Action Demo",
            startURL: "https://drel.app/test/actions/v1/index.html",
            allowedOrigins: [origin],
            capabilities: [.location],
            capabilitiesV2: [
                HTMLAppActionDeclaration(
                    action: .location,
                    origins: [origin],
                    purposeId: "demo-location",
                    purpose: "获取当前位置完成演示",
                    scope: scope
                )
            ],
            routes: ["/"],
            cache: HTMLAppCachePolicy(
                strategy: .networkOnly,
                version: "1",
                persistent: false,
                restoresLastState: true
            )
        )
    }

    private func makeGateway(
        manifest: HTMLAppManifest,
        storage: HTMLAppRuntimeStorage
    ) throws -> HTMLAppCapabilityGateway {
        let registry = HTMLAppTrustRegistry(storage: storage)
        let ledger = HTMLAppPermissionLedger(storage: storage)
        // 不吞错误：注册失败必须直接暴露（此前 try? 掩盖了 setup 问题，
        // 导致所有用例都因 appNotRegistered 失败，掩盖了真实断言结果）
        try registry.register(manifest, trustPolicy: .development)
        return HTMLAppCapabilityGateway(
            trustRegistry: registry,
            permissionLedger: ledger,
            nativeAuthorizationProvider: GrantedProvider()
        )
    }

    private func subject() -> HTMLAppPermissionSubject {
        HTMLAppPermissionSubject(
            gatewayIdentity: "gateway#key",
            appID: appID,
            origin: origin
        )
    }

    private func makeRequest() -> HTMLAppCapabilityRequest {
        HTMLAppCapabilityRequest(
            id: UUID().uuidString,
            capability: .location,
            reason: "获取当前位置",
            scope: .always,
            purposeId: "demo-location"
        )
    }

    /// 真机场景（2026-10-22 用户反馈）：定位声明只能为 .always（框架校验强制
    /// —— grant 类动作声明为 .once/.appSession 会让 manifest 注册失败）。
    /// 用户在面板选「始终允许」后必须落账，且下次调用免询问。
    func testAlwaysGrantPersistsAndFastPaths() throws {
        let storage = MemoryStorage()
        let gateway = try makeGateway(manifest: makeManifest(scope: .always), storage: storage)
        let subj = subject()

        // 首次：无授权 → 应返回 notDetermined（弹面板）
        // 注意：pending 按 request.id 定位，首次请求与 resolveUserConsent 必须
        // 用同一个 request，否则会被判为 userCancelled。
        let consentRequest = makeRequest()
        let first = gateway.requestAuthorization(
            subject: subj,
            documentURL: documentURL,
            request: consentRequest
        )
        XCTAssertEqual(
            first.status, .notDetermined,
            "首次调用应请求用户授权（实际 status=\(first.status), reason=\(String(describing: first.failureReason))）"
        )

        // 模拟用户在面板选「始终允许」→ 系统授权通过 → 落账
        let granted = expectation(description: "consent resolved")
        gateway.resolveUserConsent(
            subject: subj,
            documentURL: documentURL,
            request: consentRequest,
            approvedScope: .always,
            granted: true
        ) { result in
            XCTAssertEqual(
                result.status, .granted,
                "用户选始终允许应得到 granted（实际 status=\(result.status), reason=\(String(describing: result.failureReason))）"
            )
            granted.fulfill()
        }
        wait(for: [granted], timeout: 2)

        // 关键断言：再次请求必须免询问放行
        let second = gateway.requestAuthorization(
            subject: subj,
            documentURL: documentURL,
            request: makeRequest()
        )
        XCTAssertEqual(
            second.status, .granted,
            "始终允许后再次调用必须免询问（实际 status=\(second.status), reason=\(String(describing: second.failureReason))）"
        )
        XCTAssertEqual(second.scope, .always)

        // 授权记录必须仍在账本中（杀掉 App 重开后能读回）
        let ledger = HTMLAppPermissionLedger(storage: storage)
        let remaining = ledger.grants(for: appID)
        XCTAssertTrue(
            remaining.contains { $0.capability == .location && $0.scope == .always },
            "始终允许授权必须留在账本中（否则冷启动后丢失）"
        )
    }

    /// 对照组：「允许一次」不得免询问（一次性事实，下次必须重新弹面板）
    func testOnceScopeReprompts() throws {
        let storage = MemoryStorage()
        let gateway = try makeGateway(manifest: makeManifest(scope: .always), storage: storage)
        let subj = subject()

        let onceRequest = makeRequest()
        _ = gateway.requestAuthorization(subject: subj, documentURL: documentURL, request: onceRequest)
        let granted = expectation(description: "consent resolved")
        gateway.resolveUserConsent(
            subject: subj,
            documentURL: documentURL,
            request: onceRequest,
            approvedScope: .once,
            granted: true
        ) { _ in granted.fulfill() }
        wait(for: [granted], timeout: 2)

        XCTAssertEqual(
            gateway.requestAuthorization(subject: subj, documentURL: documentURL, request: makeRequest()).status,
            .notDetermined,
            "「允许一次」后再次调用必须重新弹面板"
        )
    }
}
