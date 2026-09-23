import Foundation

extension Notification.Name {
    static let fileMannWebDAVProgress = Notification.Name("filemann.webdav.progress")
    static let fileMannWebDAVCompleted = Notification.Name("filemann.webdav.completed")
    static let fileMannWebDAVFailed = Notification.Name("filemann.webdav.failed")
}

private struct BackgroundUploadDescriptor: Codable {
    let taskID: UUID
    let partialPath: String
    let finalPath: String
    let expectedBytes: Int64
}

final class WebDAVBackgroundUploadManager: NSObject {
    static let shared = WebDAVBackgroundUploadManager()
    static let sessionIdentifier = "com.masakacj.filemann.webdav.background"

    private var backgroundCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = makeSession()

    private override init() {
        super.init()
    }

    func schedule(
        taskID: UUID,
        sourceURL: URL,
        request: URLRequest,
        partialPath: String,
        finalPath: String,
        expectedBytes: Int64
    ) throws {
        let descriptor = BackgroundUploadDescriptor(
            taskID: taskID,
            partialPath: partialPath,
            finalPath: finalPath,
            expectedBytes: expectedBytes
        )
        let data = try JSONEncoder().encode(descriptor)

        guard let description = String(data: data, encoding: .utf8) else {
            throw WebDAVArchiveError.invalidResponse
        }

        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart || FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw WebDAVArchiveError.sourceUnavailable
        }

        let upload = session.uploadTask(with: request, fromFile: sourceURL)
        upload.taskDescription = description
        upload.resume()
    }

    func suspendAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.suspend() }
        }
    }

    func resumeAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.resume() }
        }
    }

    func cancel(taskID: UUID) {
        session.getAllTasks { tasks in
            for task in tasks {
                guard let descriptor = self.descriptor(for: task),
                      descriptor.taskID == taskID else {
                    continue
                }
                task.cancel()
            }
        }
    }

    func activeTaskIDs() async -> Set<UUID> {
        let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }

        return Set(tasks.compactMap { descriptor(for: $0)?.taskID })
    }

    func setBackgroundCompletionHandler(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
    }

    private func makeSession() -> URLSession {
        let settings = TaskStore.loadSettings()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = !settings.webDAVWiFiOnly
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7

        let queue = OperationQueue()
        queue.name = "FileMann.WebDAV.Background"
        queue.maxConcurrentOperationCount = 1

        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
    }

    private func descriptor(for task: URLSessionTask) -> BackgroundUploadDescriptor? {
        guard let value = task.taskDescription,
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(BackgroundUploadDescriptor.self, from: data)
    }

    private func postFailure(taskID: UUID, message: String) {
        NotificationCenter.default.post(
            name: .fileMannWebDAVFailed,
            object: nil,
            userInfo: [
                "taskID": taskID,
                "message": message
            ]
        )
    }
}

extension WebDAVBackgroundUploadManager: URLSessionTaskDelegate, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let descriptor = descriptor(for: task) else { return }

        NotificationCenter.default.post(
            name: .fileMannWebDAVProgress,
            object: nil,
            userInfo: [
                "taskID": descriptor.taskID,
                "sent": totalBytesSent,
                "expected": max(totalBytesExpectedToSend, descriptor.expectedBytes)
            ]
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let descriptor = descriptor(for: task) else { return }

        if let error {
            postFailure(taskID: descriptor.taskID, message: error.localizedDescription)
            return
        }

        guard let response = task.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            postFailure(
                taskID: descriptor.taskID,
                message: status >= 0 ? "HTTP \(status)" : "上传未收到有效响应"
            )
            return
        }

        Task {
            do {
                let settings = TaskStore.loadSettings()
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: KeychainStore.loadWebDAVPassword()
                )
                let result = try await service.finalizeBackgroundUpload(
                    partialPath: descriptor.partialPath,
                    finalPath: descriptor.finalPath,
                    expectedBytes: descriptor.expectedBytes
                )

                NotificationCenter.default.post(
                    name: .fileMannWebDAVCompleted,
                    object: nil,
                    userInfo: [
                        "taskID": descriptor.taskID,
                        "remotePath": result.remotePath,
                        "remoteSize": result.remoteSize
                    ]
                )
            } catch {
                postFailure(
                    taskID: descriptor.taskID,
                    message: "服务器校验/落盘失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
