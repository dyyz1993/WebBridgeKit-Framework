import Foundation

public final class URLSessionHTMLAppPackageTransport: NSObject, HTMLAppPackageTransport, @unchecked Sendable {
    private struct PendingDownload {
        let maximumBytes: Int64
        let progress: @Sendable (_ bytesWritten: Int64, _ expectedBytes: Int64) -> Void
        let continuation: CheckedContinuation<HTMLAppPackageTransportResponse, Error>
    }

    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var pending: [Int: PendingDownload] = [:]

    public override init() {
        super.init()
    }

    public func data(from url: URL, maximumBytes: Int) async throws -> HTMLAppPackageTransportResponse {
        try await data(from: url, maximumBytes: maximumBytes) { _, _ in }
    }

    public func data(
        from url: URL,
        maximumBytes: Int,
        progress: @escaping @Sendable (_ bytesWritten: Int64, _ expectedBytes: Int64) -> Void
    ) async throws -> HTMLAppPackageTransportResponse {
        guard maximumBytes >= 0 else { throw HTMLAppOfflinePackageError.resourceManifestTooLarge }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            lock.withLock {
                pending[task.taskIdentifier] = PendingDownload(
                    maximumBytes: Int64(maximumBytes),
                    progress: progress,
                    continuation: continuation
                )
            }
            task.resume()
        }
    }

    private func finish(taskID: Int, result: Result<HTMLAppPackageTransportResponse, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: taskID)?.continuation }
        continuation?.resume(with: result)
    }
}

extension URLSessionHTMLAppPackageTransport: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let pendingDownload = lock.withLock { pending[downloadTask.taskIdentifier] }
        let maximum = pendingDownload?.maximumBytes
        pendingDownload?.progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        if let maximum,
           totalBytesWritten > maximum || (totalBytesExpectedToWrite > maximum && totalBytesExpectedToWrite > 0) {
            downloadTask.cancel()
            finish(taskID: downloadTask.taskIdentifier, result: .failure(HTMLAppOfflinePackageError.resourceManifestTooLarge))
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let maximum = lock.withLock { pending[downloadTask.taskIdentifier]?.maximumBytes } ?? 0
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max
            guard size <= maximum else {
                finish(taskID: downloadTask.taskIdentifier, result: .failure(HTMLAppOfflinePackageError.resourceManifestTooLarge))
                return
            }
            guard let response = downloadTask.response,
                  let finalURL = response.url else {
                throw HTMLAppOfflinePackageError.transportFailed("missing response")
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw HTMLAppOfflinePackageError.transportFailed("HTTP \(http.statusCode)")
            }
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            finish(taskID: downloadTask.taskIdentifier, result: .success(.init(data: data, finalURL: finalURL)))
        } catch {
            finish(taskID: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let exists = lock.withLock { pending[task.taskIdentifier] != nil }
        if exists {
            finish(
                taskID: task.taskIdentifier,
                result: .failure(HTMLAppOfflinePackageError.transportFailed(error.localizedDescription))
            )
        }
    }
}
