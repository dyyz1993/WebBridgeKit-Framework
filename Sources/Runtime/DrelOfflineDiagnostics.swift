import Foundation
import UIKit

/// Local-only diagnostics for a single Drel HTML app launch.
///
/// The payload is intentionally whitelist-only: no tokens, cookies, query or
/// fragment values, page text, form data, or absolute on-device paths are
/// stored. Raw errors are reduced to a domain and numeric code.
public final class DrelOfflineDiagnostics: @unchecked Sendable {
    public static let shared = DrelOfflineDiagnostics()
    public static let maximumAttempts = 20
    public static let maximumStorageBytes = 96 * 1024

    /// Product hook for the release diagnostics screen. The framework never
    /// presents product UI itself.
    public static var presentationProvider: ((UIViewController, String) -> Void)?

    private struct Storage: Codable {
        var attempts: [Attempt] = []
    }

    public struct Attempt: Codable, Equatable, Sendable, Identifiable {
        public enum Phase: String, Codable, Sendable {
            case launch
            case package
            case navigation
            case page
            case fallback
            case api
        }

        public enum Status: String, Codable, Sendable {
            case started
            case succeeded
            case failed
            case skipped
            case timedOut
        }

        public enum LoadSource: String, Codable, Sendable {
            case offlinePackage
            case online
            case unknown
        }

        public struct Event: Codable, Equatable, Sendable {
            public let timestamp: Date
            public let phase: Phase
            public let status: Status
            public let loadSource: LoadSource
            public let errorDomain: String?
            public let errorCode: Int64?
            public let path: String?
            public let httpStatusCode: Int?
            public let outcome: String?
        }

        public let id: String
        public let startedAt: Date
        public let hostVersion: String
        public let hostBuild: String
        public let appID: String
        public let packageVersion: String?
        public let manifestDigestPrefix: String?
        public let launchSource: String
        public var events: [Event]

        public var currentLoadSource: LoadSource {
            events.reversed().first { $0.loadSource != .unknown }?.loadSource ?? .unknown
        }

        public var failurePhase: Phase? {
            events.reversed().first { $0.status == .failed }?.phase
        }
    }

    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager
    private var storage: Storage

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let defaultRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? defaultRoot
            .appendingPathComponent("WebBridgeKit/Diagnostics", isDirectory: true)
            .appendingPathComponent("offline-attempts.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    @discardableResult
    public func beginAttempt(
        appID: String,
        packageVersion: String?,
        manifestDigestPrefix: String?,
        source: String,
        now: Date = Date()
    ) -> Attempt {
        let info = Bundle.main.infoDictionary ?? [:]
        let attempt = Attempt(
            id: UUID().uuidString,
            startedAt: now,
            hostVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            hostBuild: info["CFBundleVersion"] as? String ?? "unknown",
            appID: appID,
            packageVersion: packageVersion,
            manifestDigestPrefix: Self.digestPrefix(manifestDigestPrefix),
            launchSource: Self.controlledSource(source),
            events: [.init(
                timestamp: now,
                phase: .launch,
                status: .started,
                loadSource: .unknown,
                errorDomain: nil,
                errorCode: nil,
                path: nil,
                httpStatusCode: nil,
                outcome: "launched"
            )]
        )
        lock.lock()
        storage.attempts.append(attempt)
        trimLocked()
        persistLocked()
        lock.unlock()
        return attempt
    }

    public func record(
        attemptID: String,
        phase: Attempt.Phase,
        status: Attempt.Status,
        loadSource: Attempt.LoadSource = .unknown,
        error: Error? = nil,
        path: String? = nil,
        httpStatusCode: Int? = nil,
        outcome: String? = nil,
        now: Date = Date()
    ) {
        let controlledError = error.map(Self.controlledError)
        let event = Attempt.Event(
            timestamp: now,
            phase: phase,
            status: status,
            loadSource: loadSource,
            errorDomain: controlledError?.domain,
            errorCode: controlledError?.code,
            path: path.map(Self.safeRelativePath),
            httpStatusCode: httpStatusCode.map { min(max($0, 0), 599) },
            outcome: outcome.map(Self.safeOutcome)
        )
        lock.lock()
        guard let index = storage.attempts.firstIndex(where: { $0.id == attemptID }) else {
            lock.unlock()
            return
        }
        storage.attempts[index].events.append(event)
        if storage.attempts[index].events.count > 100 {
            storage.attempts[index].events.removeFirst(storage.attempts[index].events.count - 100)
        }
        persistLocked()
        lock.unlock()
    }

    public func attempts(appID: String? = nil) -> [Attempt] {
        lock.lock()
        defer { lock.unlock() }
        let values = storage.attempts.suffix(Self.maximumAttempts)
        guard let appID else { return Array(values.reversed()) }
        return values.filter { $0.appID == appID }.reversed()
    }

    public func attempt(id: String) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        return storage.attempts.first { $0.id == id }
    }

    public func copyReport(appID: String? = nil) -> String {
        let values = attempts(appID: appID)
        let report: [String: Any] = [
            "schema": "drel.offline.diagnostics.v1",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "attempts": values.map(asWhitelistedDictionary)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"schema\":\"drel.offline.diagnostics.v1\",\"error\":\"encoding_failed\"}"
        }
        return text
    }

    public func clear() {
        lock.lock()
        storage.attempts.removeAll()
        persistLocked()
        lock.unlock()
    }

    private func asWhitelistedDictionary(_ attempt: Attempt) -> [String: Any] {
        [
            "attemptId": attempt.id,
            "startedAt": ISO8601DateFormatter().string(from: attempt.startedAt),
            "hostVersion": attempt.hostVersion,
            "hostBuild": attempt.hostBuild,
            "appId": attempt.appID,
            "packageVersion": attempt.packageVersion ?? "",
            "manifestDigestPrefix": attempt.manifestDigestPrefix ?? "",
            "launchSource": attempt.launchSource,
            "currentSource": attempt.currentLoadSource.rawValue,
            "failurePhase": attempt.failurePhase?.rawValue ?? "",
            "events": attempt.events.map { event in
                [
                    "time": ISO8601DateFormatter().string(from: event.timestamp),
                    "phase": event.phase.rawValue,
                    "status": event.status.rawValue,
                    "source": event.loadSource.rawValue,
                    "errorDomain": event.errorDomain ?? "",
                    "errorCode": event.errorCode.map(String.init) ?? "",
                    "path": event.path ?? "",
                    "httpStatus": event.httpStatusCode.map(String.init) ?? "",
                    "outcome": event.outcome ?? ""
                ]
            }
        ]
    }

    private static func controlledError(_ error: Error) -> (domain: String, code: Int64) {
        let nsError = error as NSError
        let allowedDomains: Set<String> = [
            NSURLErrorDomain,
            NSCocoaErrorDomain,
            "WKErrorDomain",
            "NSURLErrorDomain"
        ]
        let domain = allowedDomains.contains(nsError.domain) ? nsError.domain : "controlled"
        let code = Int64(clamping: nsError.code)
        return (domain, code)
    }

    private static func safeRelativePath(_ value: String) -> String {
        let pathOnly = value.prefix { $0 != "?" && $0 != "#" }
        let components = pathOnly.split(separator: "/").map(String.init)
        let sanitized = components.filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }
        return sanitized.joined(separator: "/").prefix(180).description
    }

    private static func safeOutcome(_ value: String) -> String {
        let allowed: Set<String> = [
            "launched", "resolved", "packageFound", "packageMissing", "digestMismatch", "entrypointMissing",
            "versionMismatch", "webContentProcessTerminated",
            "navigationStarted", "navigationFinished", "fallbackStarted", "fallbackSucceeded", "fallbackUnavailable",
            "pageReady", "pageVisible", "keyElementMissing", "scriptError", "resourceError", "apiSucceeded",
            "apiUnauthorized", "apiFailed", "apiNetworkError", "retry"
        ]
        return allowed.contains(value) ? value : "controlled"
    }

    private static func controlledSource(_ value: String) -> String {
        let allowed: Set<String> = ["direct", "notification", "restore", "externalLink", "catalog", "push"]
        return allowed.contains(value) ? value : "controlled"
    }

    private static func digestPrefix(_ value: String?) -> String? {
        guard let value, value.count == 64, value.allSatisfy({ $0.isHexDigit && $0.isLowercase }) else { return nil }
        return String(value.prefix(12))
    }

    private func trimLocked() {
        if storage.attempts.count > Self.maximumAttempts {
            storage.attempts.removeFirst(storage.attempts.count - Self.maximumAttempts)
        }
    }

    private func persistLocked() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(storage)
            while data.count > Self.maximumStorageBytes, storage.attempts.count > 1 {
                storage.attempts.removeFirst(max(1, storage.attempts.count / 10))
                data = try encoder.encode(storage)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never alter the launch path.
        }
    }
}
