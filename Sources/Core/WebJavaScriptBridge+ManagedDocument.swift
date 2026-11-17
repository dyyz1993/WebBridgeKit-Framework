import Foundation

extension WebJavaScriptBridge {
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
}
