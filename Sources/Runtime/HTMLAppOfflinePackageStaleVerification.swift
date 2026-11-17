import Foundation

extension HTMLAppOfflinePackageLocator {
    /// Internal accessor for the active version directory. Offline launch
    /// verification tests share this module-private layout.
    func versionDirectory(for package: InstalledHTMLAppPackage) -> URL {
        packageRoot(for: package)
    }

    /// Full offline verification of the installed package against the signed
    /// parent manifest persisted at install time. Used only while offline to
    /// decide whether a stale package (one whose version trails the current
    /// signed manifest) may still launch: the injected verifier, backed by the
    /// same gateway trust anchor used at registration, must accept the
    /// persisted parent, the parent must pin the persisted resource manifest
    /// digest, and every declared file on disk must still match its recorded
    /// digest. Any broken link returns nil. Packages installed before parent
    /// manifests were persisted never qualify, and nil-verifier callers are
    /// always rejected so a stale package is never served on local metadata
    /// consistency alone.
    public func verifiedStaleOfflinePackage(
        appID: String,
        signatureVerifier: ((HTMLAppManifest) -> Bool)?
    ) -> InstalledHTMLAppPackage? {
        guard let installed = try? installedPackage(appID: appID),
              let parent = installed.signedParentManifest,
              let signatureVerifier else { return nil }
        // The persisted parent must describe exactly this installation before
        // any cryptographic work. The verifier is host-supplied and may be
        // lenient, so identity binding never relies on it alone.
        guard parent.appID == installed.appID, installed.appID == appID,
              parent.effectiveOfflineCache.version == installed.version else { return nil }
        guard parent.validate(requiringSignature: true).isValid, signatureVerifier(parent) else { return nil }
        let cache = parent.effectiveOfflineCache
        guard cache.isStrongOfflineEligible,
              let pinnedDigest = cache.resourceManifestSHA256,
              pinnedDigest == installed.resourceManifestSHA256 else { return nil }
        // The pinned resource manifest location must still satisfy the
        // signed parent own origin policy.
        guard let pinnedURLString = cache.resourceManifestURL,
              let pinnedURL = URL(string: pinnedURLString),
              pinnedURL.scheme?.lowercased() == "https",
              parent.allows(documentURL: pinnedURL) else { return nil }

        let root = packageRoot(for: installed)
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let descriptorURL = root.appendingPathComponent(Self.resourceDescriptorFilename)
        guard let descriptorSize = Self.boundedRegularFileSize(
                  at: descriptorURL, withinRoot: rootPath, maximumBytes: 4_194_304
              ),
              let descriptorData = try? Data(contentsOf: descriptorURL),
              Int64(descriptorData.count) == descriptorSize,
              Self.sha256(descriptorData) == pinnedDigest,
              let descriptor = try? JSONDecoder().decode(HTMLAppOfflinePackageManifest.self, from: descriptorData) else { return nil }
        guard descriptor.schemaVersion == HTMLAppOfflinePackageManifest.supportedSchemaVersion,
              descriptor.appID == installed.appID,
              descriptor.version == installed.version,
              descriptor.entrypoint == installed.entrypoint,
              Self.validateOfflineContents(descriptor, in: root, rootPath: rootPath, originAuthority: parent) else { return nil }
        return installed
    }

    /// Re-checks every declared file on disk against its recorded size and
    /// digest plus the installer structural rules. The signed parent remains
    /// the origin authority: every recorded download URL must still satisfy
    /// its policy even though the bytes are already pinned. Symbolic links
    /// must not move reads outside the version directory, and the declared
    /// sizes must respect the installer package caps. Signature expiry is not
    /// checked here because the manifest signature schema carries no expiry
    /// or revocation field; key rotation by the gateway invalidates old
    /// signatures through the injected verifier instead.
    private static func validateOfflineContents(
        _ descriptor: HTMLAppOfflinePackageManifest,
        in root: URL,
        rootPath: String,
        originAuthority: HTMLAppManifest
    ) -> Bool {
        guard !descriptor.files.isEmpty, descriptor.files.count <= 2_000 else { return false }
        var seen = Set<String>()
        var totalBytes: Int64 = 0
        for file in descriptor.files {
            guard HTMLAppOfflinePackageInstaller.isSafeRelativePath(file.path),
                  file.path != resourceDescriptorFilename,
                  !file.path.hasPrefix(resourceDescriptorFilename + "/"),
                  seen.insert(file.path).inserted else { return false }
            for existing in seen where existing != file.path {
                if existing.hasPrefix(file.path + "/") || file.path.hasPrefix(existing + "/") {
                    return false
                }
            }
            guard let url = URL(string: file.url),
                  url.scheme?.lowercased() == "https",
                  originAuthority.allows(documentURL: url) else { return false }
            guard HTMLAppCachePolicy.isValidSHA256(file.sha256),
                  file.size >= 0, file.size <= 33_554_432 else { return false }
            let (next, overflow) = totalBytes.addingReportingOverflow(file.size)
            guard !overflow, next <= 262_144_000 else { return false }
            totalBytes = next
            let fileURL = root.appendingPathComponent(file.path, isDirectory: false)
            guard let onDiskSize = Self.boundedRegularFileSize(
                      at: fileURL, withinRoot: rootPath, maximumBytes: file.size
                  ),
                  let data = try? Data(contentsOf: fileURL),
                  Int64(data.count) == onDiskSize,
                  Int64(data.count) == file.size,
                  Self.sha256(data) == file.sha256 else { return false }
        }
        return seen.contains(descriptor.entrypoint)
    }

    /// Returns the size of a plain regular file whose resolved path stays
    /// inside rootPath and whose size fits maximumBytes, or nil otherwise.
    /// Callers read after this check and must revalidate the byte count so a
    /// file swapped between the two steps cannot blow up memory. Internal so
    /// the main locator file's existing verification path keeps sharing it.
    static func boundedRegularFileSize(
        at url: URL,
        withinRoot rootPath: String,
        maximumBytes: Int64
    ) -> Int64? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0, size <= maximumBytes else { return nil }
        return size
    }
}
