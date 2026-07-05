//
//  BackgroundUploader.swift
//  DropSwift
//
//  Runs uploads on a BACKGROUND URLSession so a transfer keeps going while the
//  app is suspended or the phone is locked. The system daemon (nsurlsessiond)
//  performs the actual transfer and wakes the app to continue the queue.
//
//  Background sessions can't use the async/completion convenience methods, so we
//  drive raw upload tasks through the session delegate and bridge each one back
//  to async/await with a continuation.
//
//  Limitations (iOS rules we can't change):
//   • If the user FORCE-QUITS the app, iOS cancels in-flight transfers.
//   • If the system evicts the app, the bytes still finish in the daemon, but
//     the in-app queue/progress for not-yet-finished items isn't reconstructed.
//

import Foundation

final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let identifier = "com.avik.DropSwift.upload.background"

    /// Per-task state: the response body accumulates here, progress is forwarded,
    /// and the continuation is resumed when the task finishes.
    private final class TaskBox {
        var received = Data()
        let onProgress: @Sendable (Double) -> Void
        let onBytes: @Sendable (Int64) -> Void
        let cont: CheckedContinuation<(Data, URLResponse), Error>
        init(onProgress: @escaping @Sendable (Double) -> Void,
             onBytes: @escaping @Sendable (Int64) -> Void,
             cont: CheckedContinuation<(Data, URLResponse), Error>) {
            self.onProgress = onProgress
            self.onBytes = onBytes
            self.cont = cont
        }
    }

    private let lock = NSLock()
    private var boxes: [Int: TaskBox] = [:]     // taskIdentifier -> state
    private var systemCompletion: (() -> Void)?

    /// The one background session for the app (reconnects to outstanding tasks
    /// on relaunch because the identifier is stable).
    private(set) lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.isDiscretionary = false            // user-initiated: run promptly
        c.sessionSendsLaunchEvents = true    // wake the app to continue the queue
        c.waitsForConnectivity = true        // survive brief Wi-Fi blips
        c.httpMaximumConnectionsPerHost = ServerConnection.maxParallelUploads
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 60 * 60 * 24 * 3   // multi-day for huge batches
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Ensures the session (and thus the delegate) exists so relaunch events for
    /// outstanding background tasks are delivered.
    func activate() { _ = session }

    /// Uploads a file on the background session; resumes when the task completes.
    /// Cancels the underlying task if the awaiting Task is cancelled.
    func upload(_ request: URLRequest, fromFile fileURL: URL,
                onProgress: @escaping @Sendable (Double) -> Void,
                onBytes: @escaping @Sendable (Int64) -> Void) async throws -> (Data, URLResponse) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let box = TaskBox(onProgress: onProgress, onBytes: onBytes, cont: cont)
                lock.lock(); boxes[task.taskIdentifier] = box; lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Stashes the system's completion handler (from the app delegate) so we can
    /// call it once all background events for this launch are delivered.
    func setSystemCompletion(_ handler: @escaping () -> Void) {
        lock.lock(); systemCompletion = handler; lock.unlock()
    }

    // MARK: - URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.lock(); let box = boxes[task.taskIdentifier]; lock.unlock()
        box?.onBytes(bytesSent)
        guard totalBytesExpectedToSend > 0 else { return }
        box?.onProgress(min(1.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); boxes[dataTask.taskIdentifier]?.received.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let box = boxes.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let box else { return }   // a task from a previous launch — nothing awaiting it
        if let error {
            box.cont.resume(throwing: error)
        } else if let response = task.response {
            box.cont.resume(returning: (box.received, response))
        } else {
            box.cont.resume(throwing: URLError(.badServerResponse))
        }
    }

    /// All background events for this wake-up have been delivered — let the
    /// system put the app back to sleep.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let handler = systemCompletion; systemCompletion = nil; lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
