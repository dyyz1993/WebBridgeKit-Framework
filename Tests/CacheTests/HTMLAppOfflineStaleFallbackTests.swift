import CryptoKit
import XCTest
@testable import WebBridgeKit

/// Regression coverage for launching an installed offline package whose
/// version trails the current signed manifest. The fallback engages only
/// while offline and only for packages whose persisted signed parent
/// manifest still verifies and whose on-disk bytes match the digest chain.
/// The fixture mirrors the real VOT package layout, whose resource files
/// include a manifest.json entry that must never be clobbered by installer
/// metadata.
final class HTMLAppOfflineStaleFallbackTests: XCTestCase {
    private final class MemoryStorage: HTMLAppRuntimeStorage {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data?, forKey key: String) { values[key] = data }
    }

    private actor MemoryTransport: HTMLAppPackageTransport {
        var responses: [URL: HTMLAppPackageTransportResponse]

        init(responses: [URL: HTMLAppPackageTransportResponse]) {
            self.responses = responses
        }

        func data(from url: URL, maximumBytes: Int) async throws -> HTMLAppPackageTransportResponse {
            guard let response = responses[url] else {
                throw URLError(.notConnectedToInternet)
            }
            guard response.data.count <= maximumBytes else {
                throw HTMLAppOfflinePackageError.resourceManifestTooLarge
            }
            return response
        }
    }

    private var root: URL!
    private let origin = URL(string: "https://fixture.example.invalid:8443")!
    private let appID = "app.fixture.example.invalid"
    private let signingKey = Curve25519.Signing.PrivateKey()
    private let keyID = "gw-test-key"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLAppOfflineStaleFallbackTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    // MARK: - Install integrity with real VOT layout

    func testInstallKeepsVOTResourcesIntactAndPersistsSignedParent() async throws {
        let fixture = try await installVOTPackage()

        let manifestResource = try Data(
            contentsOf: fixture.versionDirectory.appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(manifestResource, fixture.webAppManifestBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest").path
            )
        )
        XCTAssertEqual(fixture.installed.signedParentManifest?.appID, appID)

        let locator = HTMLAppOfflinePackageLocator(packagesRoot: root)
        let restored = try locator.installedPackage(appID: appID)
        XCTAssertEqual(restored?.signedParentManifest, fixture.installed.signedParentManifest)
    }

    // MARK: - Offline fallback across restart

    func testOfflineFallbackLaunchesSignedStalePackageAcrossRestart() async throws {
        let fixture = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .strong)
        XCTAssertTrue(target.loaderURL.isFileURL)
        XCTAssertEqual(
            target.loaderURL.standardizedFileURL.resolvingSymlinksInPath().path,
            fixture.versionDirectory.appendingPathComponent("drel.html").standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try String(contentsOf: target.loaderURL), "<html drel v0.4.10.4>")

        let manifestResource = fixture.versionDirectory.appendingPathComponent("manifest.json")
        XCTAssertEqual(try Data(contentsOf: manifestResource), fixture.webAppManifestBytes)
    }

    func testOnlinePolicyKeepsSkippingStalePackage() async throws {
        _ = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(appID: appID, route: "/drel.html")

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertEqual(target.loaderURL, origin.appendingPathComponent("drel.html"))
        XCTAssertNil(target.installedPackageURL)
    }

    // MARK: - Fail-closed conditions

    func testFallbackStaysBlockedWithoutVerifier() async throws {
        _ = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root)
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenSignatureVerifierRejects() async throws {
        _ = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let foreignKey = Curve25519.Signing.PrivateKey()
        let foreignVerifier = HTMLAppGatewayOnboardingService.offlineFallbackSignatureVerifier(
            publicKeyID: keyID,
            publicKey: base64URL(foreignKey.publicKey.rawRepresentation)
        )
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: foreignVerifier
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedForLegacyInstallWithoutParentManifest() async throws {
        _ = try await installVOTPackage()
        try stripPersistedParentManifest()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenPersistedParentIsTampered() async throws {
        _ = try await installVOTPackage()
        try mutatePersistedParent { manifest in
            manifest["startURL"] = "https://attacker.example.com/drel.html"
        }
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenDescriptorIsTampered() async throws {
        let fixture = try await installVOTPackage()
        var descriptor = try Data(
            contentsOf: fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest")
        )
        descriptor.append(0x20)
        try descriptor.write(
            to: fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest")
        )
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenResourceFileIsTampered() async throws {
        let fixture = try await installVOTPackage()
        try Data("{ replaced }".utf8).write(
            to: fixture.versionDirectory.appendingPathComponent("manifest.json")
        )
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    // MARK: - Hardening: identity binding beyond the verifier

    func testFallbackStaysBlockedWhenPersistedParentIdentityMismatches() async throws {
        _ = try await installVOTPackage()
        try mutatePersistedParent { manifest in
            manifest["appId"] = "app.attacker.example.invalid"
        }
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: { _ in true }
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenPersistedParentVersionMismatches() async throws {
        _ = try await installVOTPackage()
        try mutatePersistedParent { manifest in
            var cache = manifest["cache"] as! [String: Any]
            cache["version"] = "9.9.9.9"
            manifest["cache"] = cache
            var drelOffline = manifest["drel_offline"] as! [String: Any]
            drelOffline["version"] = "9.9.9.9"
            manifest["drel_offline"] = drelOffline
        }
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: { _ in true }
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackEnforcesSignedParentOriginPolicyOnDescriptorURLs() async throws {
        let fixture = try await installVOTPackage()
        let descriptorURL = fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest")
        var descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL)) as! [String: Any]
        var files = descriptor["files"] as! [[String: Any]]
        for index in files.indices where files[index]["path"] as? String == "style.css" {
            files[index]["url"] = "https://attacker.example.com/drel/v0.4.10.4/style.css"
        }
        descriptor["files"] = files
        let mutatedDescriptor = try JSONSerialization.data(withJSONObject: descriptor)
        try mutatedDescriptor.write(to: descriptorURL)

        let forgedParent = try makeSignedParent(version: "0.4.10.4", digest: digest(mutatedDescriptor))
        try rewritePersistedState(installed: fixture.installed, parent: forgedParent, digest: digest(mutatedDescriptor))

        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: { _ in true }
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenFileIsSymbolicLinkEscape() async throws {
        let fixture = try await installVOTPackage()
        let victim = fixture.versionDirectory.appendingPathComponent("drel-config.js")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-fallback-escape-\(UUID().uuidString).js")
        try Data(contentsOf: victim).write(to: outside)
        try FileManager.default.removeItem(at: victim)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testDescriptorReadStaysBoundedAndRootConfined() async throws {
        let fixture = try await installVOTPackage()
        let descriptorURL = fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest")
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = makeResolver(currentManifest: updated)

        let oversized = Data((0..<4_194_305).map { UInt8($0 % 251) })
        try oversized.write(to: descriptorURL)
        var target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )
        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-fallback-descriptor-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: descriptorURL)
        try FileManager.default.createSymbolicLink(at: descriptorURL, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )
        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    func testFallbackStaysBlockedWhenDeclaredSizesExceedCaps() async throws {
        let fixture = try await installVOTPackage()
        let descriptorURL = fixture.versionDirectory.appendingPathComponent(".drel-verified-resource-manifest")
        var descriptor = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL)) as! [String: Any]
        var files = descriptor["files"] as! [[String: Any]]
        for index in files.indices where files[index]["path"] as? String == "style.css" {
            files[index]["size"] = 33_554_433
        }
        descriptor["files"] = files
        let mutatedDescriptor = try JSONSerialization.data(withJSONObject: descriptor)
        try mutatedDescriptor.write(to: descriptorURL)
        let forgedParent = try makeSignedParent(version: "0.4.10.4", digest: digest(mutatedDescriptor))
        try rewritePersistedState(installed: fixture.installed, parent: forgedParent, digest: digest(mutatedDescriptor))

        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let resolver = HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: updated),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: { _ in true }
        )

        let target = try resolver.resolve(
            appID: appID,
            route: "/drel.html",
            networkPolicy: .offlineFallback
        )

        XCTAssertEqual(target.offlineMode, .partial)
        XCTAssertNil(target.installedPackageURL)
    }

    // MARK: - Bridge page identity consistency

    func testLogicalDocumentURLGrantsIdentityToVerifiedStalePackageOffline() async throws {
        let fixture = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))
        let locator = HTMLAppOfflinePackageLocator(packagesRoot: root)
        let verifier = gatewayVerifier()
        let entrypoint = fixture.versionDirectory.appendingPathComponent("drel.html")

        let entryIdentity = locator.logicalDocumentURL(
            for: entrypoint,
            parent: updated,
            launchPage: origin.appendingPathComponent("drel.html"),
            offlineFallback: true,
            signatureVerifier: verifier
        )
        XCTAssertEqual(entryIdentity, origin.appendingPathComponent("drel.html"))

        let resourceIdentity = locator.logicalDocumentURL(
            for: fixture.versionDirectory.appendingPathComponent("manifest.json"),
            parent: updated,
            launchPage: origin.appendingPathComponent("drel.html"),
            offlineFallback: true,
            signatureVerifier: verifier
        )
        XCTAssertEqual(resourceIdentity, origin.appendingPathComponent("drel/v0.4.10.4/manifest.json"))

        let withoutFallback = locator.logicalDocumentURL(
            for: entrypoint,
            parent: updated,
            launchPage: origin.appendingPathComponent("drel.html")
        )
        XCTAssertNil(withoutFallback)
    }

    func testFallbackIdentityUsesSignedParentOriginAuthority() async throws {
        let fixture = try await installVOTPackage()
        let movedOrigin = "https://moved-fixture.example.invalid:8443"
        let updated = try makeSignedParent(
            version: "0.4.10.5",
            digest: String(repeating: "b", count: 64),
            allowedOrigins: [movedOrigin]
        )
        let locator = HTMLAppOfflinePackageLocator(packagesRoot: root)

        let resourceIdentity = locator.logicalDocumentURL(
            for: fixture.versionDirectory.appendingPathComponent("manifest.json"),
            parent: updated,
            launchPage: URL(string: "https://moved-fixture.example.invalid:8443/drel.html"),
            offlineFallback: true,
            signatureVerifier: gatewayVerifier()
        )

        XCTAssertEqual(resourceIdentity, origin.appendingPathComponent("drel/v0.4.10.4/manifest.json"))
    }

    func testBridgeWiredThroughRuntimeHooksGrantsVerifiedStalePageIdentity() async throws {
        let fixture = try await installVOTPackage()
        let updated = try makeSignedParent(version: "0.4.10.5", digest: String(repeating: "b", count: 64))

        HTMLAppOfflineFallbackRuntime.signatureVerifier = gatewayVerifier()
        HTMLAppOfflineFallbackRuntime.isOfflineProvider = { true }

        let wired = makeBridge(registryManifest: updated)
        XCTAssertEqual(
            wired.effectiveManagedDocumentURL(
                fixture.versionDirectory.appendingPathComponent("drel.html")
            ),
            origin.appendingPathComponent("drel.html")
        )
        XCTAssertEqual(
            wired.effectiveManagedDocumentURL(
                fixture.versionDirectory.appendingPathComponent("manifest.json")
            ),
            origin.appendingPathComponent("drel/v0.4.10.4/manifest.json")
        )

        HTMLAppOfflineFallbackRuntime.signatureVerifier = nil
        HTMLAppOfflineFallbackRuntime.isOfflineProvider = nil
        let unwired = makeBridge(registryManifest: updated)
        XCTAssertNil(unwired.effectiveManagedDocumentURL(
            fixture.versionDirectory.appendingPathComponent("drel.html")
        ))
    }

    private func makeBridge(registryManifest: HTMLAppManifest) -> WebJavaScriptBridge {
        let registry = HTMLAppTrustRegistry(storage: MemoryStorage())
        try? registry.register(registryManifest)
        let bridge = WebJavaScriptBridge(
            trustRegistry: registry,
            permissionLedger: HTMLAppPermissionLedger(storage: MemoryStorage()),
            nativeAuthorizationProvider: StubNativeAuthorizationProvider(),
            gatewayIdentity: nil,
            offlinePackageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            offlineFallbackSignatureVerifier: HTMLAppOfflineFallbackRuntime.signatureVerifier,
            isOfflineProvider: HTMLAppOfflineFallbackRuntime.isOfflineProvider
        )
        bridge.configureManagedHTMLApp(
            appID: appID,
            documentURL: origin.appendingPathComponent("drel.html")
        )
        return bridge
    }

    private final class StubNativeAuthorizationProvider: HTMLAppNativeAuthorizationProviding {
        func authorizationStatus(for capability: HTMLAppCapability) -> HTMLAppCapabilityResult.Status {
            .granted
        }

        func requestAuthorization(
            for capability: HTMLAppCapability,
            completion: @escaping (HTMLAppCapabilityResult.Status) -> Void
        ) {
            completion(.granted)
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        var installed: InstalledHTMLAppPackage
        var versionDirectory: URL
        var parent: HTMLAppManifest
        var webAppManifestBytes: Data
    }

    private func gatewayVerifier() -> ((HTMLAppManifest) -> Bool)? {
        HTMLAppGatewayOnboardingService.offlineFallbackSignatureVerifier(
            publicKeyID: keyID,
            publicKey: base64URL(signingKey.publicKey.rawRepresentation)
        )
    }

    private func makeResolver(currentManifest: HTMLAppManifest) -> HTMLAppLaunchResolver {
        HTMLAppLaunchResolver(
            trustRegistry: makeRegistry(current: currentManifest),
            packageLocator: HTMLAppOfflinePackageLocator(packagesRoot: root),
            signatureVerifier: gatewayVerifier()
        )
    }

    private func makeRegistry(current: HTMLAppManifest) -> HTMLAppTrustRegistry {
        let registry = HTMLAppTrustRegistry(storage: MemoryStorage())
        try? registry.register(current)
        return registry
    }

    private func makeSignedParent(version: String, digest: String) throws -> HTMLAppManifest {
        try makeSignedParent(version: version, digest: digest, allowedOrigins: [origin.absoluteString])
    }

    private func makeSignedParent(
        version: String,
        digest: String,
        allowedOrigins: [String]
    ) throws -> HTMLAppManifest {
        let unsigned = HTMLAppManifest(
            appID: appID,
            name: "VOT",
            startURL: origin.appendingPathComponent("drel.html").absoluteString,
            allowedOrigins: allowedOrigins,
            capabilities: [],
            routes: ["/", "/index.html", "/drel.html"],
            cache: HTMLAppCachePolicy(strategy: .manifest, version: version, persistent: true),
            drelOffline: DrelOfflinePackageDeclaration(
                version: version,
                resourceManifestURL: origin.appendingPathComponent("drel/v\(version)/package.json").absoluteString,
                resourceManifestSHA256: digest
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(unsigned)
        let signatureData = try signingKey.signature(for: payload)
        return HTMLAppManifest(
            appID: unsigned.appID,
            name: unsigned.name,
            startURL: unsigned.startURL,
            allowedOrigins: unsigned.allowedOrigins,
            capabilities: unsigned.capabilities,
            routes: unsigned.routes,
            cache: unsigned.cache,
            drelOffline: unsigned.drelOffline,
            signature: HTMLAppManifestSignature(
                algorithm: "ed25519",
                keyID: keyID,
                value: base64URL(signatureData)
            )
        )
    }

    private func installVOTPackage() async throws -> Fixture {
        let version = "0.4.10.4"
        let webAppManifestBytes = Data("""
        {"name":"VOT","short_name":"VOT","start_url":"./drel.html","display":"standalone","background_color":"#101418","theme_color":"#5B5CE2"}
        """.utf8)
        let fileContents: [String: Data] = [
            "diagnostics.html": Data("<html>diagnostics</html>".utf8),
            "drel-app.js": Data("console.log('vot app v\(version)');".utf8),
            "drel-config.js": Data("window.VOT_CONFIG={};".utf8),
            "drel.html": Data("<html drel v\(version)>".utf8),
            "manifest.json": webAppManifestBytes,
            "style.css": Data("body{margin:0}".utf8),
            "vot-icon.png": Data([0x89, 0x50, 0x4E, 0x47])
        ]
        let packageFiles = fileContents.keys.sorted().map { path in
            HTMLAppOfflinePackageFile(
                path: path,
                url: origin.appendingPathComponent("drel/v\(version)/\(path)").absoluteString,
                sha256: digest(fileContents[path] ?? Data()),
                size: Int64((fileContents[path] ?? Data()).count),
                mimeType: "application/octet-stream"
            )
        }
        let resourceManifest = HTMLAppOfflinePackageManifest(
            appID: appID,
            version: version,
            entrypoint: "drel.html",
            files: packageFiles
        )
        let manifestData = try JSONEncoder().encode(resourceManifest)
        let manifestURL = origin.appendingPathComponent("drel/v\(version)/package.json")
        var responses: [URL: HTMLAppPackageTransportResponse] = [
            manifestURL: .init(data: manifestData, finalURL: manifestURL)
        ]
        for (path, data) in fileContents {
            let url = origin.appendingPathComponent("drel/v\(version)/\(path)")
            responses[url] = .init(data: data, finalURL: url)
        }

        let parent = try makeSignedParent(version: version, digest: digest(manifestData))
        let installer = HTMLAppOfflinePackageInstaller(
            transport: MemoryTransport(responses: responses),
            packagesRoot: root
        )
        let installed = try await installer.install(appManifest: parent)
        let locator = HTMLAppOfflinePackageLocator(packagesRoot: root)
        return Fixture(
            installed: installed,
            versionDirectory: locator.versionDirectory(for: installed),
            parent: parent,
            webAppManifestBytes: webAppManifestBytes
        )
    }

    private func stripPersistedParentManifest() throws {
        let metadataURL = root
            .appendingPathComponent(sha256Hex(appID))
            .appendingPathComponent("installed.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        object.removeValue(forKey: "signedParentManifest")
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
    }

    private func mutatePersistedParent(_ mutation: (inout [String: Any]) -> Void) throws {
        let metadataURL = root
            .appendingPathComponent(sha256Hex(appID))
            .appendingPathComponent("installed.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        var parent = object["signedParentManifest"] as! [String: Any]
        mutation(&parent)
        object["signedParentManifest"] = parent
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
    }

    private func rewritePersistedState(
        installed: InstalledHTMLAppPackage,
        parent: HTMLAppManifest,
        digest: String
    ) throws {
        let metadataURL = root
            .appendingPathComponent(sha256Hex(appID))
            .appendingPathComponent("installed.json")
        let rebuilt = InstalledHTMLAppPackage(
            appID: installed.appID,
            version: installed.version,
            entrypoint: installed.entrypoint,
            directoryName: installed.directoryName,
            resourceManifestSHA256: digest,
            installedAt: installed.installedAt,
            signedParentManifest: parent
        )
        try JSONEncoder().encode(rebuilt).write(to: metadataURL)
        let currentURL = root
            .appendingPathComponent(sha256Hex(appID))
            .appendingPathComponent("current.json")
        try JSONEncoder().encode(rebuilt).write(to: currentURL)
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
