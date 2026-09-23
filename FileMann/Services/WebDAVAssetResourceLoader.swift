import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class WebDAVAssetResourceLoader:
    NSObject,
    AVAssetResourceLoaderDelegate {

    private let path: String
    private let settings: SMBSettings
    private let password: String
    private let preferredBaseURLString: String

    private let lock = NSLock()
    private var workers: [ObjectIdentifier: WebDAVRangeWorker] = [:]

    init(
        path: String,
        settings: SMBSettings,
        password: String,
        preferredBaseURLString: String
    ) {
        self.path = path
        self.settings = settings
        self.password = password
        self.preferredBaseURLString = preferredBaseURLString
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource
            loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let worker = WebDAVRangeWorker(
            loadingRequest: loadingRequest,
            path: path,
            settings: settings,
            password: password,
            preferredBaseURLString: preferredBaseURLString
        ) { [weak self] in
            self?.lock.lock()
            self?.workers.removeValue(forKey: key)
            self?.lock.unlock()
        }

        lock.lock()
        workers[key] = worker
        lock.unlock()

        worker.start()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)

        lock.lock()
        let worker = workers.removeValue(forKey: key)
        lock.unlock()

        worker?.cancel()
    }
}

private final class WebDAVRangeWorker:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate {

    private let loadingRequest: AVAssetResourceLoadingRequest
    private let path: String
    private let settings: SMBSettings
    private let password: String
    private let candidates: [String]
    private let completion: () -> Void

    private var candidateIndex = 0
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deliveredBytes = false
    private var finished = false

    init(
        loadingRequest: AVAssetResourceLoadingRequest,
        path: String,
        settings: SMBSettings,
        password: String,
        preferredBaseURLString: String,
        completion: @escaping () -> Void
    ) {
        self.loadingRequest = loadingRequest
        self.path = path
        self.settings = settings
        self.password = password

        var values = [preferredBaseURLString]
        for value in settings.webDAVCandidateBaseURLs
            where !values.contains(value) {
            values.append(value)
        }
        self.candidates = values
        self.completion = completion
    }

    func start() {
        startAttempt()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        finishCleanup()
    }

    private func startAttempt() {
        guard candidateIndex < candidates.count else {
            finish(
                error: WebDAVArchiveError.noReachableEndpoint
            )
            return
        }

        guard let baseURL = URL(
            string: candidates[candidateIndex]
        ) else {
            candidateIndex += 1
            startAttempt()
            return
        }

        var url = baseURL
        for component in path
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/ ")
            )
            .split(separator: "/")
            .map(String.init) {
            url.appendPathComponent(component)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60

        if !settings.webDAVUsername.isEmpty {
            let token = Data(
                "\(settings.webDAVUsername):\(password)".utf8
            ).base64EncodedString()
            request.setValue(
                "Basic \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }

        if let dataRequest = loadingRequest.dataRequest {
            let start = max(
                dataRequest.currentOffset,
                dataRequest.requestedOffset
            )

            if dataRequest.requestsAllDataToEndOfResource {
                request.setValue(
                    "bytes=\(start)-",
                    forHTTPHeaderField: "Range"
                )
            } else {
                let length = max(1, dataRequest.requestedLength)
                let end = start + Int64(length) - 1
                request.setValue(
                    "bytes=\(start)-\(end)",
                    forHTTPHeaderField: "Range"
                )
            }
        } else {
            request.setValue(
                "bytes=0-1",
                forHTTPHeaderField: "Range"
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess =
            !settings.webDAVWiFiOnly

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
        self.session = session

        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
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
            completionHandler: completionHandler
        )
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard candidateIndex < candidates.count else {
            completionHandler(
                .performDefaultHandling,
                nil
            )
            return
        }

        let candidate = candidates[candidateIndex]
        let endpoint = WebDAVChallengeHandler.endpoint(
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler:
            @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            tryNext(
                error: WebDAVArchiveError.invalidResponse
            )
            return
        }

        let requestedOffset =
            loadingRequest.dataRequest?.currentOffset
            ?? loadingRequest.dataRequest?.requestedOffset
            ?? 0

        guard (200...299).contains(http.statusCode),
              !(requestedOffset > 0 && http.statusCode == 200) else {
            completionHandler(.cancel)
            tryNext(
                error: WebDAVArchiveError.unexpectedStatus(
                    http.statusCode
                )
            )
            return
        }

        if let info = loadingRequest.contentInformationRequest {
            let totalLength = Self.totalLength(from: http)
            if let totalLength {
                info.contentLength = totalLength
            }

            if let mime = http.value(
                forHTTPHeaderField: "Content-Type"
            )?.split(separator: ";").first {
                info.contentType = UTType(
                    mimeType: String(mime)
                )?.identifier
            }

            let acceptsRanges = http.statusCode == 206 ||
                http.value(
                    forHTTPHeaderField: "Accept-Ranges"
                )?.lowercased().contains("bytes") == true
            info.isByteRangeAccessSupported = acceptsRanges
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !finished else { return }
        deliveredBytes = true
        loadingRequest.dataRequest?.respond(with: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }

        if let error {
            if !deliveredBytes {
                tryNext(error: error)
            } else {
                finish(error: error)
            }
            return
        }

        loadingRequest.finishLoading()
        finished = true
        finishCleanup()
    }

    private func tryNext(error: Error) {
        guard !finished else { return }

        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil

        guard !deliveredBytes else {
            finish(error: error)
            return
        }

        candidateIndex += 1
        if candidateIndex < candidates.count {
            startAttempt()
        } else {
            finish(error: error)
        }
    }

    private func finish(error: Error) {
        guard !finished else { return }
        finished = true
        loadingRequest.finishLoading(with: error)
        finishCleanup()
    }

    private func finishCleanup() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        completion()
    }

    private static func totalLength(
        from response: HTTPURLResponse
    ) -> Int64? {
        if let contentRange = response.value(
            forHTTPHeaderField: "Content-Range"
        ),
           let total = contentRange
            .split(separator: "/")
            .last,
           let value = Int64(total) {
            return value
        }

        if let contentLength = response.value(
            forHTTPHeaderField: "Content-Length"
        ),
           let value = Int64(contentLength) {
            return value
        }

        return nil
    }
}
