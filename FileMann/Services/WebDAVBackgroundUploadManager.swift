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
    // Retain the original identifier so tasks submitted by older versions
    // are still reattached and finished after an in-place upgrade.
    static let sessionIdentifier = "com.masakacj.filemann.webdav.background"
    static let localSessionIdentifier =
        "com.masakacj.filemann.webdav.background.local"
    static let remoteSessionIdentifier =
        "com.masakacj.filemann.webdav.background.remote"
    private static let supportedSessionIdentifiers: Set<String> = [
        sessionIdentifier, localSessionIdentifier, remoteSessionIdentifier
    ]

    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    // Do not tell UIKit that all background callbacks have been processed
    // while an asynchronous NAS MOVE + parent PROPFIND is still running.
    private let pendingFinalizations = DispatchGroup()
    private let finalizingLock = NSLock()
    private var finalizingTaskIDs = Set<UUID>()

    private lazy var legacySession: URLSession = makeSession(
        identifier: Self.sessionIdentifier,
        maximumConnections: WebDAVUploadSchedulingPolicy.maximumWANHTTPConnections
    )
    private lazy var localSession: URLSession = makeSession(
        identifier: Self.localSessionIdentifier,
        maximumConnections: WebDAVUploadSchedulingPolicy.maximumLANHTTPConnections
    )
    private lazy var remoteSession: URLSession = makeSession(
        identifier: Self.remoteSessionIdentifier,
        maximumConnections: WebDAVUploadSchedulingPolicy.maximumWANHTTPConnections
    )
    private var allSessions: [URLSession] {
        [legacySession, localSession, remoteSession]
    }

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
        uploadMode: WebDAVUploadMode,
        usesLocalLAN: Bool
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

        let uploadSession = usesLocalLAN ? localSession : remoteSession
        let upload = uploadSession.uploadTask(with: request, fromFile: sourceURL)
        upload.taskDescription = description
        upload.resume()
    }

    private func forEachSubmittedTask(
        _ action: @escaping (URLSessionTask) -> Void
    ) {
        for session in allSessions {
            session.getAllTasks { tasks in
                tasks.forEach(action)
            }
        }
    }

    func suspendAll() {
        forEachSubmittedTask { $0.suspend() }
    }

    func resumeAll() {
        forEachSubmittedTask { $0.resume() }
    }

    /// Cancels all current and legacy FileMann URLSession uploads only.
    /// This never deletes NAS or Photos originals.
    func cancelAll() {
        forEachSubmittedTask { $0.cancel() }
    }

    func cancel(taskID: UUID) {
        forEachSubmittedTask { task in
            guard self.descriptor(for: task)?.taskID == taskID else {
                return
            }
            task.cancel()
        }
    }

    func activeTaskIDs() async -> Set<UUID> {
        var active = pendingFinalizingIDs()
        for session in allSessions {
            let ids: Set<UUID> = await withCheckedContinuation {
                continuation in
                session.getAllTasks { tasks in
                    let ids = Set(tasks.compactMap {
                        self.descriptor(for: $0)?.taskID
                    })
                    continuation.resume(returning: ids)
                }
            }
            active.formUnion(ids)
        }
        // The system can remove a PUT task before its MOVE/PROPFIND
        // finishes. Keep it in-flight until a verified receipt exists.
        active.formUnion(pendingFinalizingIDs())
        return active
    }

    private func pendingFinalizingIDs() -> Set<UUID> {
        finalizingLock.lock()
        defer { finalizingLock.unlock() }
        return finalizingTaskIDs
    }

    private func markFinalizing(_ id: UUID, active: Bool) {
        finalizingLock.lock()
        defer { finalizingLock.unlock() }
        if active {
            finalizingTaskIDs.insert(id)
        } else {
            finalizingTaskIDs.remove(id)
        }
    }

    /// Re-attach to tasks held by iOS's background transfer daemon.
    /// Lazy session construction alone is insufficient on a background
    /// relaunch because the UI might never be presented.
    func reconnectBackgroundSession() {
        // Re-create all identifiers: the system may wake either new session,
        // or the original pre-upgrade session, without displaying SwiftUI.
        _ = allSessions
    }

    func setBackgroundCompletionHandler(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard Self.supportedSessionIdentifiers.contains(identifier) else {
            completionHandler()
            return
        }
        backgroundCompletionHandlers[identifier] = completionHandler
        reconnectBackgroundSession()
    }

    private func makeSession(
        identifier: String,
        maximumConnections: Int
    ) -> URLSession {
        let settings = TaskStore.loadSettings()
        let configuration = URLSessionConfiguration.background(
            withIdentifier: identifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = !settings.webDAVWiFiOnly
        configuration.httpMaximumConnectionsPerHost = maximumConnections
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
        // A callback may arrive before any SwiftUI view model or observer
        // exists after an iOS system relaunch.
        try? WebDAVBackgroundReceiptStore.save(
            .failed(taskID: taskID, message: message)
        )
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

        pendingFinalizations.enter()
        markFinalizing(descriptor.taskID, active: true)
        Task {
            defer {
                markFinalizing(descriptor.taskID, active: false)
                pendingFinalizations.leave()
            }
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

                // The journal is written BEFORE the in-process notification.
                // If iOS suspends the app before its ViewModel processes the
                // callback, the verified result survives the next launch.
                try WebDAVBackgroundReceiptStore.save(
                    .verified(
                        taskID: descriptor.taskID,
                        endpoint: descriptor.baseURLString,
                        path: result.remotePath,
                        size: result.remoteSize
                    )
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
        guard let identifier = session.configuration.identifier else {
            return
        }
        pendingFinalizations.notify(queue: .main) {
            let handler = self.backgroundCompletionHandlers.removeValue(
                forKey: identifier
            )
            handler?()
        }
    }
}
