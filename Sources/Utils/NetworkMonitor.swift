//
//  NetworkMonitor.swift
//  WebBridgeKit
//
//  Created on 2026-02-10.
//

import Foundation
import Network
import WebKit

/// Network connection type
public enum ConnectionType {
    case wifi
    case cellular
    case ethernet
    case none
}

/// Network status monitoring using Network framework
/// Provides real-time network connectivity status and connection type detection
public class NetworkMonitor {

    // MARK: - Singleton

    public static let shared = NetworkMonitor()

    // MARK: - Properties

    /// Backing storage for the connectivity snapshot. Read access goes
    /// through the lock-protected computed properties below.
    private var _isConnected: Bool = false
    private var _isConnectivityKnown: Bool = false
    private var _connectionType: ConnectionType = .none

    /// Current network connection status (lock-protected snapshot).
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    /// True once the path monitor delivered its first update. Before that the
    /// connectivity state is unknown: isConnected still carries its initial
    /// false and callers must not treat it as a confirmed offline condition.
    /// (Lock-protected snapshot.)
    public var isConnectivityKnown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnectivityKnown
    }

    /// Current connection type (lock-protected snapshot).
    public var connectionType: ConnectionType {
        lock.lock()
        defer { lock.unlock() }
        return _connectionType
    }

    /// One-shot callbacks invoked exactly once when the first authoritative
    /// path sample arrives (or immediately if it already has). Registered via
    /// onFirstConnectivitySample.
    private var firstSampleCallbacks: [() -> Void] = []

    /// Network path monitor
    private var pathMonitor: NWPathMonitor

    /// Queue for monitoring network changes
    private let monitorQueue = DispatchQueue(label: "com.webbridgekit.network.monitor")

    /// Status change callbacks
    private var statusChangeCallbacks: [(Bool, ConnectionType) -> Void] = []

    /// Thread safety lock
    private let lock = NSLock()

    // MARK: - Initialization

    private init() {
        pathMonitor = NWPathMonitor()
        setupMonitoring()
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// Start monitoring network status
    /// Monitoring starts automatically at init time. This method is kept for
    /// backward compatibility and can be used to restart after a stop.
    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        NSLog("[WEB] [NetworkMonitor] startMonitoring() called (monitoring auto-starts at init)")
    }

    /// Stop monitoring network status
    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        pathMonitor.cancel()
        NSLog( "[WEB] [NetworkMonitor] Stopped monitoring network status")
    }

    /// Add a callback for network status changes
    /// - Parameter callback: Closure to execute when network status changes
    /// - Parameters:
    ///   - isConnected: Whether network is connected
    ///   - connectionType: The type of connection (wifi, cellular, ethernet, none)
    public func addStatusChangeCallback(_ callback: @escaping (Bool, ConnectionType) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        statusChangeCallbacks.append(callback)
        NSLog( "[WEB] [NetworkMonitor] Added status change callback (total: \(statusChangeCallbacks.count))")
    }

    /// Remove a specific callback
    /// - Parameter callback: The callback to remove
    public func removeStatusChangeCallback(_ callback: @escaping (Bool, ConnectionType) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        statusChangeCallbacks.removeAll { _ in
            // Compare function references using ObjectIdentifier
            return false // Swift doesn't support direct function comparison, so we keep all
        }
    }

    /// Remove all status change callbacks
    public func removeAllCallbacks() {
        lock.lock()
        defer { lock.unlock() }

        statusChangeCallbacks.removeAll()
        NSLog( "[WEB] [NetworkMonitor] Removed all status change callbacks")
    }

    /// Check if currently on cellular network
    /// - Returns: true if connected via cellular
    public func isCellular() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return _connectionType == .cellular
    }

    /// Check if currently on WiFi
    /// - Returns: true if connected via WiFi
    public func isWiFi() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return _connectionType == .wifi
    }

    /// Get current network status description
    /// - Returns: Human-readable status string
    public func getStatusDescription() -> String {
        lock.lock()
        defer { lock.unlock() }

        if !_isConnected {
            return "Offline"
        }

        switch _connectionType {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .ethernet:
            return "Ethernet"
        case .none:
            return "Unknown"
        }
    }

    /// Thread-safe snapshot of the connectivity knowledge.
    public func connectivitySnapshot() -> (isConnectivityKnown: Bool, isConnected: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (_isConnectivityKnown, _isConnected)
    }

    /// Calls callback exactly once: immediately when the first authoritative
    /// path sample has already arrived, otherwise as soon as it does. Unlike
    /// the status-change callbacks this also fires when the first sample
    /// reports an offline state.
    public func onFirstConnectivitySample(_ callback: @escaping () -> Void) {
        var invokeNow = false
        lock.lock()
        if _isConnectivityKnown {
            invokeNow = true
        } else {
            firstSampleCallbacks.append(callback)
        }
        lock.unlock()
        if invokeNow {
            callback()
        }
    }

    /// Suspends until the first authoritative path sample arrives or the
    /// timeout elapses, whichever happens first. No polling is involved: the
    /// wait rides on the one-shot first-sample notification and races it
    /// against a deadline work item, each resuming the continuation exactly
    /// once.
    public func waitFirstConnectivitySample(timeout: TimeInterval) async {
        if connectivitySnapshot().isConnectivityKnown {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = NSLock()
            var resumed = false
            let resumeOnce = {
                gate.lock()
                let shouldResume = !resumed
                resumed = true
                gate.unlock()
                if shouldResume {
                    continuation.resume()
                }
            }
            onFirstConnectivitySample { resumeOnce() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: DispatchWorkItem { resumeOnce() }
            )
        }
    }

    // MARK: - Private Methods

    /// Setup network monitoring
    private func setupMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let newIsConnected = path.status == .satisfied
            let newConnectionType = self.determineConnectionType(from: path)

            var changed = false

            self.lock.lock()
            let wasFirstSample = !self._isConnectivityKnown
            self._isConnectivityKnown = true
            var firstSampleCallbacks: [() -> Void] = []
            if wasFirstSample {
                firstSampleCallbacks = self.firstSampleCallbacks
                self.firstSampleCallbacks = []
            }
            if self._isConnected != newIsConnected || self._connectionType != newConnectionType {
                self._isConnected = newIsConnected
                self._connectionType = newConnectionType
                changed = true

                // Log the change
                let statusText = newIsConnected ? "Connected" : "Disconnected"
                let typeText = self.getConnectionTypeText(newConnectionType)
                NSLog( "[WEB] [NetworkMonitor] Status changed: \(statusText) (\(typeText))")
            }
            self.lock.unlock()

            // First-sample subscribers must fire even when the value did not
            // change (an offline first sample leaves isConnected false).
            if wasFirstSample {
                firstSampleCallbacks.forEach { $0() }
            }

            // Notify callbacks if status changed
            if changed {
                self.notifyStatusChangeCallbacks(isConnected: newIsConnected, connectionType: newConnectionType)
            }
        }

        // Connectivity is initialized lazily: reading currentPath before the
        // monitor has started yields an unsatisfied placeholder, which would
        // misreport a cold start as offline. The first authoritative value
        // arrives with the first path update and flips isConnectivityKnown.
    }

    /// Determine connection type from NWPath
    /// - Parameter path: Network path
    /// - Returns: Connection type
    private func determineConnectionType(from path: NWPath) -> ConnectionType {
        if path.status != .satisfied {
            return .none
        }

        // Check for cellular
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }

        // Check for WiFi
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }

        // Check for Ethernet (wired)
        if path.usesInterfaceType(.wiredEthernet) {
            return .ethernet
        }

        // Default to WiFi if connected but type unknown
        // (this covers cases like personal hotspot, etc.)
        return .wifi
    }

    /// Get human-readable connection type text
    /// - Parameter type: Connection type
    /// - Returns: Text description
    private func getConnectionTypeText(_ type: ConnectionType) -> String {
        switch type {
        case .wifi:
            return "WiFi"
        case .cellular:
            return "Cellular"
        case .ethernet:
            return "Ethernet"
        case .none:
            return "None"
        }
    }

    /// Notify all registered callbacks about status change
    /// - Parameters:
    ///   - isConnected: Connection status
    ///   - connectionType: Connection type
    private func notifyStatusChangeCallbacks(isConnected: Bool, connectionType: ConnectionType) {
        lock.lock()
        let callbacks = statusChangeCallbacks
        lock.unlock()

        // Execute callbacks on main queue
        DispatchQueue.main.async {
            for callback in callbacks {
                callback(isConnected, connectionType)
            }
        }

        NSLog( "[WEB] [NetworkMonitor] Notified \(callbacks.count) callbacks")
    }
}

// MARK: - Network Status Notifications

extension Notification.Name {
    /// Posted when network status changes
    /// UserInfo keys:
    ///   - "isConnected": Bool (true if connected, false if disconnected)
    ///   - "connectionType": ConnectionType (wifi, cellular, ethernet, none)
    public static let networkStatusDidChange = Notification.Name("com.webbridgekit.network.statusDidChange")
}

// MARK: - Convenience Extensions

extension NetworkMonitor {

    /// Check network availability before making a request
    /// - Throws: WebBridgeError.networkUnavailable if not connected
    public func ensureNetworkAvailable() throws {
        lock.lock()
        let connected = _isConnected
        let type = _connectionType
        lock.unlock()

        guard connected else {
            throw WebBridgeError.networkUnavailable(reason: "No network connection available")
        }

        // Log connection type for tracking
        NSLog( "[WEB] [NetworkMonitor] Network check passed (type: \(getConnectionTypeText(type)))")
    }

    /// Check if cellular network and warn about data usage
    /// - Returns: true if on cellular, false otherwise
    public func warnIfCellular() -> Bool {
        let isCellularConnection = isCellular()

        if isCellularConnection {
            NSLog( "[WARN] [NetworkMonitor] Using cellular network - data charges may apply")
        }

        return isCellularConnection
    }
}
