// Foreground, level-only microphone monitoring for web apps.
import AVFoundation
import UIKit
import WebKit

public class WebAudioLevelHandler: BaseWebNativeHandler, HTMLAppCapabilityRevocationHandling {
    private var audioEngine: AVAudioEngine?
    private var levelTimer: DispatchSourceTimer?
    private var isMonitoring = false
    private var generation = 0 // Main queue only.
    private var backgroundObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private let levelLock = NSLock()
    private var currentRMS: Float = 0
    private var sensitivity: Float = 5
    // Injectable to exercise the system permission prompt's inactive -> active transition.
    var applicationStateProvider: () -> UIApplication.State = { UIApplication.shared.applicationState }

    public override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop(notify: true) }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.stop(notify: true)
        }
    }

    public override func handle(body: [String: Any], completion: @escaping (Any) -> Void) {
        let params = body["params"] as? [String: Any] ?? body
        let action = params["action"] as? String ?? "start"
        let fps = min(30, max(1, (params["fps"] as? NSNumber)?.intValue ?? 30))
        let rawSensitivity = (params["sensitivity"] as? NSNumber)?.floatValue ?? 5
        let sensitivity = rawSensitivity.isFinite ? min(20, max(0, rawSensitivity)) : 5
        let work = { [weak self] in
            guard let self else { return }
            switch action {
            case "start": self.start(fps: fps, sensitivity: sensitivity, completion: completion)
            case "stop":
                self.stop(notify: false)
                self.resolve(["message": "Monitoring stopped"], completion: completion)
            case "setSensitivity":
                self.sensitivity = sensitivity
                self.resolve(["sensitivity": sensitivity], completion: completion)
            default: self.reject(error: "Unknown action: \(action)", completion: completion)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func start(fps: Int, sensitivity: Float, completion: @escaping (Any) -> Void) {
        let session = AVAudioSession.sharedInstance()
        if applicationStateProvider() == .inactive, session.recordPermission == .granted {
            let expectedGeneration = generation
            waitForActive(expectedGeneration: expectedGeneration) { [weak self] active in
                guard let self else { return }
                if active {
                    self.start(fps: fps, sensitivity: sensitivity, completion: completion)
                } else {
                    self.reject(error: "Microphone request was cancelled", completion: completion)
                }
            }
            return
        }
        guard applicationStateProvider() == .active else {
            reject(error: "Microphone requires the foreground", completion: completion)
            return
        }
        guard !isMonitoring else {
            reject(error: "Audio monitoring is already running", completion: completion)
            return
        }
        let currentGeneration = generation
        switch session.recordPermission {
        case .denied:
            rejectPermissionDenied(type: .microphone, status: .denied, completion: completion)
            return
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.generation == currentGeneration,
                          self.applicationStateProvider() != .background else {
                        self.reject(error: "Microphone request was cancelled", completion: completion)
                        return
                    }
                    if granted {
                        self.start(fps: fps, sensitivity: sensitivity, completion: completion)
                    } else {
                        self.rejectPermissionDenied(type: .microphone, status: .denied, completion: completion)
                    }
                }
            }
            return
        case .granted: break
        @unknown default:
            reject(error: "Microphone permission unavailable", completion: completion)
            return
        }
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw NSError(domain: "WebAudioLevel", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                self.levelLock.lock()
                self.currentRMS = rms
                self.levelLock.unlock()
            }
            audioEngine = engine
            engine.prepare()
            try engine.start()
            self.sensitivity = sensitivity
            isMonitoring = true
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, self.isMonitoring else { return }
                self.levelLock.lock()
                let value = min(1, self.currentRMS * self.sensitivity)
                self.levelLock.unlock()
                // Do not log continuous microphone-derived measurements.
                self.webView?.evaluateJavaScript(
                    "window.BarkBridge?.receiveEvent('onAudioLevelChange', {level: \(value)});"
                )
            }
            levelTimer = timer
            timer.resume()
            resolve(["message": "Monitoring started", "fps": fps], completion: completion)
        } catch {
            stop(notify: false)
            reject(error: "Failed to start audio engine: \(error.localizedDescription)", completion: completion)
        }
    }

    /// A permission sheet can complete while iOS still reports `.inactive`.
    /// Bound the wait and fail closed on background, stop, or revocation.
    func waitForActive(expectedGeneration: Int, retries: Int = 20, completion: @escaping (Bool) -> Void) {
        guard generation == expectedGeneration else { completion(false); return }
        switch applicationStateProvider() {
        case .active:
            completion(true)
        case .inactive where retries > 0:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { completion(false); return }
                self.waitForActive(expectedGeneration: expectedGeneration, retries: retries - 1, completion: completion)
            }
        default:
            completion(false)
        }
    }

    private func stop(notify: Bool) {
        generation += 1
        let wasMonitoring = isMonitoring
        isMonitoring = false
        levelTimer?.cancel()
        levelTimer = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        levelLock.lock()
        currentRMS = 0
        levelLock.unlock()
        if notify && wasMonitoring { sendEventToJS(event: "onAudioLevelStopped", data: ["status": "stopped"]) }
    }

    public func htmlAppCapabilityDidRevoke() {
        if Thread.isMainThread {
            stop(notify: true)
        } else {
            DispatchQueue.main.async { [weak self] in self?.stop(notify: true) }
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        levelTimer?.cancel()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
    }
}
