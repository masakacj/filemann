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
    let baseURLString: String
    // Optional for decoding tasks scheduled by previous releases.
    let uploadMode: WebDAVUploadMode?
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
        expectedBytes: Int64,
        baseURLString: String,
        uploadMode: WebDAVUploadMode
    ) throws {
        let descriptor = BackgroundUploadDescriptor(
            taskID: taskID,
            partialPath: partialPath,
            finalPath: finalPath,
            expectedBytes: expectedBytes,
            baseURLString: baseURLString,
            uploadMode: uploadMode
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

    /// Cancel every FileMann WebDAV background task before clearing
    /// the local queue. Never issues NAS DELETE or touches Photos originals.
    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
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

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        baseURLString: String?,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let settings = TaskStore.loadSettings()
        let password = KeychainStore.loadWebDAVPassword()

        let candidate: String? = {
            if let baseURLString {
                return baseURLString
            }

            return settings.webDAVCandidateBaseURLs
                .first { value in
                    let endpoint =
                        WebDAVChallengeHandler.endpoint(
                            from: value
                        )

                    return endpoint.host?
                        .caseInsensitiveCompare(
                            challenge.protectionSpace.host
                        ) == .orderedSame &&
                        endpoint.port ==
                            challenge.protectionSpace.port
                }
        }()

        guard let candidate else {
            completionHandler(
                .performDefaultHandling,
                nil
            )
            return
        }

        let endpoint =
            WebDAVChallengeHandler.endpoint(
                from: candidate
            )

        WebDAVChallengeHandler.handle(
            challenge: challenge,
            username: settings.webDAVUsername,
            password: password,
            allowInvalidCertificate:
                settings.webDAVAllowsInvalidCertificate(
                    for: candidate
                ),
            trustedHost: endpoint.host,
            trustedPort: endpoint.port,
            completionHandler: completionHandler
        )
    }
}

extension WebDAVBackgroundUploadManager: URLSessionTaskDelegate, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Do not silently upload media to a reverse proxy login page,
        // another share, or a different host.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        handleChallenge(
            challenge,
            baseURLString: nil,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        handleChallenge(
            challenge,
            baseURLString:
                descriptor(for: task)?.baseURLString,
            completionHandler: completionHandler
        )
    }

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

        if let response = task.response as? HTTPURLResponse,
           response.statusCode == 403 {
            let path = descriptor.partialPath.hasPrefix("/")
                ? descriptor.partialPath
                : "/\(descriptor.partialPath)"
            let endpoint = TaskStore.loadSettings().webDAVTitle(
                for: descriptor.baseURLString
            )
            postFailure(
                taskID: descriptor.taskID,
                message:
                    "WebDAV（\(endpoint)）拒绝上传临时文件（PUT，HTTP 403）：\(path)。请检查归档路径、写入权限和远程代理规则。"
            )
            return
        }

        if let response = task.response as? HTTPURLResponse,
           [409, 412].contains(response.statusCode) {
            postFailure(
                taskID: descriptor.taskID,
                message: "NAS 已存在同名文件（HTTP \(response.statusCode)），已阻止覆盖；请重新命名后重试"
            )
            return
        }

        guard let response = task.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            postFailure(
                taskID: descriptor.taskID,
                message: status >= 300 && status < 400
                    ? "WebDAV PUT 返回重定向 HTTP \(status)；请修正真正的写入 URL，未确认归档"
                    : (status >= 0 ? "HTTP \(status)" : "上传未收到有效响应")
            )
            return
        }

        Task {
            do {
                let settings = TaskStore.loadSettings()
                let password = KeychainStore.loadWebDAVPassword()

                // Never silently validate a file on a different endpoint:
                // LAN and WAN WebDAV can expose different share-root paths.
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: password,
                    baseURLString: descriptor.baseURLString
                )
                let result = try await service.finalizeBackgroundUpload(
                    partialPath: descriptor.partialPath,
                    finalPath: descriptor.finalPath,
                    expectedBytes: descriptor.expectedBytes,
                    uploadMode: descriptor.uploadMode ?? .atomicMove
                )

                NotificationCenter.default.post(
                    name: .fileMannWebDAVCompleted,
                    object: nil,
                    userInfo: [
                        "taskID": descriptor.taskID,
                        "remotePath": result.remotePath,
                        "remoteSize": result.remoteSize,
                        "remoteEndpointURL": descriptor.baseURLString
                    ]
                )
            } catch {
                postFailure(
                    taskID: descriptor.taskID,
                    message: "原始上传端点的目标目录尚未确认文件，已禁止跨端点误判：\(error.localizedDescription)"
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
