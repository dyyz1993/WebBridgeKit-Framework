import Foundation
import WebKit

@MainActor
extension WebViewController {
    nonisolated static let offlineDiagnosticsMessageName = "DrelOfflineDiagnostics"

    func installOfflineDiagnosticsSupport() {
        guard !didInstallOfflineDiagnosticsSupport else { return }
        didInstallOfflineDiagnosticsSupport = true
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.offlineDiagnosticsScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let handler = WeakScriptMessageHandler(target: self)
        webView.configuration.userContentController.add(
            handler,
            name: Self.offlineDiagnosticsMessageName
        )
        registeredHandlerNames.append(Self.offlineDiagnosticsMessageName)
    }

    func handleOfflineDiagnosticsMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let eventName = body["event"] as? String else { return }

        switch eventName {
        case "pageReady":
            let keyElementFound = body["keyElementFound"] as? Bool ?? false
            let bodyVisible = body["bodyVisible"] as? Bool ?? false
            didReceiveOfflinePageReady = keyElementFound
            if keyElementFound {
                offlinePageTimeoutWorkItem?.cancel()
            }
            recordOfflineDiagnosticsEvent(
                phase: .page,
                status: keyElementFound ? .succeeded : .failed,
                loadSource: webView.url?.isFileURL == true ? .offlinePackage : .online,
                outcome: keyElementFound ? "pageReady" : "keyElementMissing"
            )
            if !keyElementFound {
                scheduleOfflinePageTimeout()
            }
        case "scriptError":
            recordOfflineDiagnosticsEvent(
                phase: .page,
                status: .failed,
                loadSource: currentOfflineDiagnosticsSource,
                outcome: "scriptError"
            )
        case "resourceError":
            recordOfflineDiagnosticsEvent(
                phase: .page,
                status: .failed,
                loadSource: currentOfflineDiagnosticsSource,
                outcome: "resourceError"
            )
        case "api":
            let statusCode = body["status"] as? Int
            let networkFailed = body["networkFailed"] as? Bool ?? false
            let outcome = networkFailed
                ? "apiNetworkError"
                : statusCode.map { $0 == 401 || $0 == 403 ? "apiUnauthorized" : (200..<400).contains($0) ? "apiSucceeded" : "apiFailed" }
            recordOfflineDiagnosticsEvent(
                phase: .api,
                status: networkFailed ? .failed : (statusCode.map { (200..<400).contains($0) ? DrelOfflineDiagnostics.Attempt.Status.succeeded : .failed } ?? .failed),
                loadSource: currentOfflineDiagnosticsSource,
                httpStatusCode: statusCode,
                outcome: outcome
            )
        default:
            break
        }
    }

    func recordOfflineDiagnosticsEvent(
        phase: DrelOfflineDiagnostics.Attempt.Phase,
        status: DrelOfflineDiagnostics.Attempt.Status,
        loadSource: DrelOfflineDiagnostics.Attempt.LoadSource = .unknown,
        error: Error? = nil,
        path: String? = nil,
        httpStatusCode: Int? = nil,
        outcome: String? = nil
    ) {
        guard let attemptID = offlineDiagnosticsAttemptID else { return }
        DrelOfflineDiagnostics.shared.record(
            attemptID: attemptID,
            phase: phase,
            status: status,
            loadSource: loadSource,
            error: error,
            path: path,
            httpStatusCode: httpStatusCode,
            outcome: outcome
        )
    }

    func scheduleOfflinePageTimeout() {
        offlinePageTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didReceiveOfflinePageReady else { return }
            self.recordOfflineDiagnosticsEvent(
                phase: .page,
                status: .timedOut,
                loadSource: self.currentOfflineDiagnosticsSource,
                outcome: "keyElementMissing"
            )
            if !self.hasAttemptedOfflinePackageFallback,
               self.currentOfflineDiagnosticsSource == .offlinePackage {
                self.recoverFromFailedOfflinePackage(URLError(.cannotParseResponse))
                return
            }
            self.presentOfflineLoadFailure()
        }
        offlinePageTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func markOfflineNavigationFinished() {
        if isRecoveringFromOfflinePackageFallback {
            isRecoveringFromOfflinePackageFallback = false
            recordOfflineDiagnosticsEvent(
                phase: .fallback,
                status: .succeeded,
                loadSource: .online,
                outcome: "fallbackSucceeded"
            )
        }
        recordOfflineDiagnosticsEvent(
            phase: .navigation,
            status: .succeeded,
            loadSource: currentOfflineDiagnosticsSource,
            outcome: "navigationFinished"
        )
        scheduleOfflinePageTimeout()
    }

    func presentOfflineLoadFailure() {
        guard !didShowOfflineLoadFailure, offlineDiagnosticsAttemptID != nil else { return }
        didShowOfflineLoadFailure = true
        let alert = UIAlertController(
            title: "应用加载失败",
            message: "离线入口没有完成可见加载。你可以查看诊断，或重试打开。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "查看诊断", style: .default) { [weak self] _ in
            guard let self else { return }
            if let provider = DrelOfflineDiagnostics.presentationProvider {
                provider(self, self.managedHTMLAppID ?? "unknown")
            } else {
                UIPasteboard.general.string = DrelOfflineDiagnostics.shared.copyReport(appID: self.managedHTMLAppID)
            }
        })
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.retryOfflineLoad()
        })
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(alert, animated: true)
    }

    private func retryOfflineLoad() {
        didReceiveOfflinePageReady = false
        didShowOfflineLoadFailure = false
        recordOfflineDiagnosticsEvent(
            phase: .launch,
            status: .started,
            loadSource: currentOfflineDiagnosticsSource,
            outcome: "retry"
        )
        let retryURL = hasAttemptedOfflinePackageFallback
            ? managedHTMLAppDocumentURL
            : initialOfflinePackageURL ?? managedHTMLAppDocumentURL
        guard let retryURL else { return }
        loadURL(retryURL, preferCachedContent: false)
    }

    var currentOfflineDiagnosticsSource: DrelOfflineDiagnostics.Attempt.LoadSource {
        webView.url?.isFileURL == true ? .offlinePackage : .online
    }

    private static let offlineDiagnosticsScript: String = """
(() => {
  if (window.__drelOfflineDiagnosticsInstalled) return;
  window.__drelOfflineDiagnosticsInstalled = true;
  const send = (value) => {
    try { window.webkit.messageHandlers.DrelOfflineDiagnostics.postMessage(value); } catch (_) {}
  };
  const reportReady = () => {
    const body = document.body;
    const rect = body ? body.getBoundingClientRect() : null;
    const bodyStyle = body ? getComputedStyle(body) : null;
    const hasVisibleText = !!body && document.body.innerText.trim().length > 0;
    const hasVisibleMedia = !!document.querySelector('canvas:not([hidden]), svg:not([hidden]), img:not([hidden]), video:not([hidden])');
    const explicitReady = document.querySelector('[data-drel-ready]');
    const contentReady = !!explicitReady || hasVisibleText || hasVisibleMedia;
    send({
      event: 'pageReady',
      bodyVisible: !!rect && rect.width > 0 && rect.height > 0 && bodyStyle.visibility !== 'hidden' && bodyStyle.display !== 'none',
      keyElementFound: contentReady
    });
  };
  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    setTimeout(reportReady, 0);
  } else {
    document.addEventListener('DOMContentLoaded', () => setTimeout(reportReady, 0), { once: true });
  }
  window.addEventListener('error', () => send({ event: 'scriptError' }), true);
  document.addEventListener('resourceerror', () => send({ event: 'resourceError' }), true);
  const fetchOriginal = window.fetch;
  if (fetchOriginal) {
    window.fetch = (...arguments) => fetchOriginal.apply(window, arguments).then((response) => {
      send({ event: 'api', status: response.status, networkFailed: false });
      return response;
    }, (error) => {
      send({ event: 'api', status: 0, networkFailed: true });
      throw error;
    });
  }
  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__drelApiRequest = true;
    return xhrOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    this.addEventListener('loadend', () => {
      if (!this.__drelApiRequest) return;
      send({ event: 'api', status: this.status, networkFailed: this.status === 0 });
    }, { once: true });
    return xhrSend.apply(this, arguments);
  };
})();
"""
}
