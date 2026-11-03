import Foundation
import UniformTypeIdentifiers

// Atomic rename is preferable, but some NAS WebDAV gateways permit PUT
// while rejecting MOVE. Direct mode is only chosen after a real write probe.
enum WebDAVUploadMode: String, Codable, Sendable {
    case atomicMove
    case directPut
}

enum WebDAVArchiveError: LocalizedError {
    case invalidBaseURL
    case noReachableEndpoint
    case unexpectedStatus(Int)
    case forbidden(operation: String, path: String)
    case duplicateArchiveDirectory(base: String, directory: String)
    case missingArchiveDestination
    case archiveDirectoryMissing(String)
    case remoteConflict(String)
    case remoteVerificationFailed
    case remoteFileNotListed(String)
    case remoteFileSizeMismatch(path: String, expected: Int64, actual: Int64?)
    case sourceUnavailable
    case sourceChanged
    case invalidResponse
    case certificateRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "WebDAV 地址无效"
        case .noReachableEndpoint:
            return "本地和远程 WebDAV 地址都无法连接"
        case .unexpectedStatus(let code):
            return "WebDAV 返回 HTTP \(code)"
        case .forbidden(let operation, let path):
            let target = path.isEmpty || path.hasPrefix("/")
                ? (path.isEmpty ? "/" : path)
                : "/\(path)"
            let hint: String
            if operation.contains("MKCOL") || operation.contains("创建目录") {
                hint = "NAS 拒绝创建文件夹。请在 WebDAV 根目录选择已存在的共享文件夹；SMB 的 storage/Documentsf/Apps 不一定是 WebDAV 路径。"
            } else if operation.contains("PUT") || operation.contains("写入") {
                hint = "NAS 允许读取但拒绝写入。请检查 WebDAV 账号对该目标文件夹的写入权限，以及代理是否放行 PUT。"
            } else if operation.contains("MOVE") || operation.contains("重命名") {
                hint = "NAS 允许上传但拒绝 MOVE 重命名，请检查 WebDAV 服务器及反向代理的 MOVE 权限。"
            } else if operation.contains("DELETE") {
                hint = "NAS 拒绝 DELETE，请检查归档文件夹的删除权限或代理方法限制。"
            } else {
                hint = "请检查账号权限、WebDAV 共享根路径和反向代理规则。"
            }
            return "WebDAV \(operation) 被拒绝（HTTP 403）：\(target)。\(hint)"
        case .duplicateArchiveDirectory(let base, let directory):
            return "WebDAV 路径重复：服务地址已包含 \(base)，归档子目录又包含 \(directory)。请将共享名或目录前缀只填写一次，以免 PUT/MKCOL 被拒绝。"
        case .missingArchiveDestination:
            return "WebDAV 当前仅指向 NAS 根目录 /，不能直接上传。请先在共享目录中选择可写文件夹，或将服务 URL 配置为包含共享名的路径（例如 /Public）。"
        case .archiveDirectoryMissing(let path):
            return "WebDAV 归档目录不存在（HTTP 404）：/\(path)。请从 WebDAV 根目录重新浏览并选择实际存在的文件夹，不要沿用 SMB 共享路径。"
        case .remoteConflict(let name):
            return "NAS 上已存在同路径文件：\(name)"
        case .remoteVerificationFailed:
            return "NAS 目标文件尚未通过实际目录验证，暂不标记成功"
        case .remoteFileNotListed(let location):
            return "NAS 目录列表中没有上传文件：\(location)。请检查实际 WebDAV 地址与共享目录映射；已保留归档任务。"
        case .remoteFileSizeMismatch(let path, let expected, let actual):
            return "NAS 目录中发现 \(path)，但大小不符（期望 \(expected) 字节，实际 \(actual.map(String.init) ?? "未知") 字节），没有确认成功。"
        case .sourceUnavailable:
            return "无法访问源文件"
        case .sourceChanged:
            return "源文件已发生变化，请重新加入任务"
        case .invalidResponse:
            return "WebDAV 返回内容无法解析"
        case .certificateRejected(let host):
            return "HTTPS 证书校验失败（\(host)）。如果这是你自己的 NAS，请到“设置 → 远程 WebDAV → 高级”开启“兼容 NAS 自签/无效证书”；也可以检查服务器证书并使用 SHA-256 指纹固定信任。"
        }
    }
}

struct RemoteMediaEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder
        case image
        case video
        case other
    }

    var id: String { path }

    let path: String
    let name: String
    let kind: Kind
    let size: Int64
    let modifiedAt: Date?
}

final class WebDAVArchiveService {
    let settings: SMBSettings
    private let password: String
    private let sessionDelegate: WebDAVSessionDelegate
    private let session: URLSession
    private let baseURL: URL
    private var cachedRemoteInventory: [RemoteFileInfo]?
    // One successful write probe establishes the archive root. Newly
    // created nested parent folders need only be checked once per batch.
    private var preparedUploadDirectories = Set<String>()

    var baseURLString: String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var endpointLabel: String {
        baseURLString == settings.normalizedWebDAVBaseURL ? "本地" : "远程"
    }

    init(
        settings: SMBSettings,
        password: String,
        baseURLString: String? = nil
    ) throws {
        self.settings = settings
        self.password = password

        let candidate = baseURLString
            ?? settings.webDAVCandidateBaseURLs.first
            ?? ""

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw WebDAVArchiveError.invalidBaseURL
        }

        self.baseURL = url

        let allowInvalidCertificate =
            settings.webDAVAllowsInvalidCertificate(
                for: candidate
            )
        let delegate = WebDAVSessionDelegate(
            username: settings.webDAVUsername,
            password: password,
            allowInvalidCertificate:
                allowInvalidCertificate,
            baseURLString: candidate
        )
        self.sessionDelegate = delegate

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy =
            .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess =
            !settings.webDAVWiFiOnly
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    static func resolveBestBaseURL(
        settings: SMBSettings,
        password: String,
        forceRemote: Bool = false
    ) async throws -> String {
        var candidates = settings.webDAVCandidateBaseURLs
        if forceRemote,
           !settings.normalizedWebDAVRemoteBaseURL.isEmpty {
            candidates.removeAll {
                $0 == settings.normalizedWebDAVRemoteBaseURL
            }
            candidates.insert(settings.normalizedWebDAVRemoteBaseURL, at: 0)
        }

        guard !candidates.isEmpty else {
            throw WebDAVArchiveError.invalidBaseURL
        }

        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            do {
                let timeout: TimeInterval = index == 0 && !forceRemote ? 1.8 : 6
                try await probe(
                    baseURLString: candidate,
                    username: settings.webDAVUsername,
                    password: password,
                    timeout: timeout,
                    allowsCellular: !settings.webDAVWiFiOnly,
                    allowInvalidCertificate:
                        settings.webDAVAllowsInvalidCertificate(
                            for: candidate
                        )
                )
                return candidate
            } catch {
                if Self.isCertificateError(error) {
                    lastError = WebDAVArchiveError.certificateRejected(
                        URL(string: candidate)?.host
                            ?? candidate
                    )
                } else {
                    lastError = error
                }
            }
        }

        throw lastError ?? WebDAVArchiveError.noReachableEndpoint
    }

    private static func isCertificateError(
        _ error: Error
    ) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            return false
        }

        return [
            -1200,
            -1201,
            -1202,
            -1203,
            -1204
        ].contains(value.code)
    }

    private static func probe(
        baseURLString: String,
        username: String,
        password: String,
        timeout: TimeInterval,
        allowsCellular: Bool,
        allowInvalidCertificate: Bool
    ) async throws {
        guard let url = URL(string: baseURLString) else {
            throw WebDAVArchiveError.invalidBaseURL
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.allowsCellularAccess = allowsCellular

        let delegate = WebDAVSessionDelegate(
            username: username,
            password: password,
            allowInvalidCertificate:
                allowInvalidCertificate,
            baseURLString: baseURLString
        )
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.timeoutInterval = timeout
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:resourcetype/></d:prop>
        </d:propfind>
        """.utf8)

        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVArchiveError.invalidResponse
        }
        guard [200, 207].contains(http.statusCode) else {
            throw WebDAVArchiveError.unexpectedStatus(http.statusCode)
        }

        // Some HTTP web servers return 200 HTML to every method (for
        // example Portainer or an incorrectly routed reverse proxy).
        // Do not mistake them for writable WebDAV endpoints.
        let resources = try WebDAVMultiStatusParser(data: data).parse()
        guard !resources.isEmpty else {
            throw WebDAVArchiveError.invalidResponse
        }
    }

    /// The WebDAV root URL and the archive directory must not both include
    /// the same share/path prefix. nPlayer can browse a share-root URL, but
    /// appending that path twice makes writes target a different location.
    private func ensureNoDuplicatedArchivePrefix(
        for remoteDirectory: String? = nil
    ) throws {
        let base = baseURL.path
            .split(separator: "/").map { String($0).lowercased() }
        let directory = (remoteDirectory ??
            settings.normalizedWebDAVDirectory)
            .split(separator: "/").map { String($0).lowercased() }
        guard !base.isEmpty, !directory.isEmpty else { return }
        let limit = min(base.count, directory.count)
        for count in 1...limit {
            if Array(base.suffix(count)) == Array(directory.prefix(count)) {
                throw WebDAVArchiveError.duplicateArchiveDirectory(
                    base: baseURL.path,
                    directory: remoteDirectory ??
                        settings.normalizedWebDAVDirectory
                )
            }
        }
    }

    func connectAndPrepare() async throws {
        try ensureNoDuplicatedArchivePrefix()
        _ = try await propfind(path: "", depth: "0")
        try await ensureDirectory(settings.normalizedWebDAVDirectory)
    }

    func testConnection() async throws {
        _ = try await preferredUploadMode()
    }

    func preferredUploadMode() async throws -> WebDAVUploadMode {
        try await verifyWritableDirectory(
            at: settings.normalizedWebDAVDirectory
        )
    }

        /// Side-effect-limited probe for an *existing* WebDAV folder. Used both
    /// by the directory picker and by transfer preflight. On success, the
    /// only remote mutations are a unique temporary file's PUT/MOVE/DELETE.
    /// The original NAS media and iPhone media are never changed.
    func verifyWritableDirectory(at path: String) async throws -> WebDAVUploadMode {
        let directory = normalize(path)
        let shareRoot = baseURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !directory.isEmpty || !shareRoot.isEmpty else {
            throw WebDAVArchiveError.missingArchiveDestination
        }

        try ensureNoDuplicatedArchivePrefix(for: directory)
        let url = remoteURL(for: directory)
        do {
            let response = try await propfind(path: directory, depth: "0")
            let resources = try WebDAVMultiStatusParser(
                data: response
            ).parse()
            guard resources.contains(where: { $0.isCollection }) else {
                throw WebDAVArchiveError.invalidResponse
            }
        } catch WebDAVArchiveError.unexpectedStatus(let code)
            where code == 404 {
            throw WebDAVArchiveError.archiveDirectoryMissing(
                url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        } catch WebDAVArchiveError.unexpectedStatus(let code)
            where code == 403 {
            throw WebDAVArchiveError.forbidden(
                operation: "PROPFIND 读取归档目录",
                path: url.path
            )
        }
        let mode = try await verifyWriteOperations(in: directory)
        preparedUploadDirectories.insert(directory)
        return mode
    }

    // The connection test must check write/rename/delete permissions, not
    // merely whether a read-only NAS share can answer PROPFIND.
    // Only disposable, UUID-named test files are touched.
    private func verifyWriteOperations(
        in directory: String
    ) async throws -> WebDAVUploadMode {
        let name = "filemann-webdav-check-" + UUID().uuidString.lowercased()
        let temporaryPath = join(directory, name + ".tmp")
        let renamedPath = join(directory, name + ".verified")
        let sample = Data("FileMann WebDAV write check".utf8)

        do {
            try await performWriteCheck(
                method: "PUT",
                path: temporaryPath,
                body: sample,
                accepted: [200, 201, 204],
                action: "写入测试文件"
            )
            guard await remoteFileSize(atPath: temporaryPath)
                    == Int64(sample.count) else {
                throw WebDAVArchiveError.remoteVerificationFailed
            }

            do {
                try await performWriteCheck(
                    method: "MOVE",
                    path: temporaryPath,
                    destinationPath: renamedPath,
                    accepted: [201, 204],
                    action: "重命名测试文件"
                )
            } catch {
                // Many gateways, including otherwise writable WebDAV
                // servers, block MOVE. A direct PUT remains usable.
                guard Self.isUnsupportedMOVE(error) else {
                    throw error
                }
                try? await performWriteCheck(
                    method: "DELETE",
                    path: temporaryPath,
                    accepted: [200, 202, 204, 404],
                    action: "清理测试文件"
                )
                return .directPut
            }

            // DELETE permission is not required to upload via PUT/MOVE.
            // A failed cleanup must not disable otherwise valid uploads.
            try? await performWriteCheck(
                method: "DELETE",
                path: renamedPath,
                accepted: [200, 202, 204, 404],
                action: "清理测试文件"
            )
            return .atomicMove
        } catch {
            try? await performWriteCheck(
                method: "DELETE",
                path: temporaryPath,
                accepted: [200, 202, 204, 404],
                action: "清理测试文件"
            )
            try? await performWriteCheck(
                method: "DELETE",
                path: renamedPath,
                accepted: [200, 202, 204, 404],
                action: "清理测试文件"
            )
            throw error
        }
    }

    private static func isUnsupportedMOVE(_ error: Error) -> Bool {
        if case WebDAVArchiveError.forbidden(_, _) = error {
            return true
        }
        if case WebDAVArchiveError.unexpectedStatus(let code) = error {
            return code == 405 || code == 501
        }
        return false
    }

    private func performWriteCheck(
        method: String,
        path: String,
        destinationPath: String? = nil,
        body: Data? = nil,
        accepted: Set<Int>,
        action: String
    ) async throws {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue(
                "application/octet-stream",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let destinationPath {
            request.setValue(
                remoteURL(for: destinationPath).absoluteString,
                forHTTPHeaderField: "Destination"
            )
            request.setValue("F", forHTTPHeaderField: "Overwrite")
        }
        applyAuthorization(to: &request)
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 403 {
            throw WebDAVArchiveError.forbidden(
                operation: action + "（" + method + "）",
                path: remoteURL(for: path).path
            )
        }
        try validate(response, accepted: accepted)
    }

    func listDirectories(at path: String) async throws -> [SMBDirectoryEntry] {
        let normalized = normalize(path)
        let data = try await propfind(path: normalized, depth: "1")
        let parser = WebDAVMultiStatusParser(data: data)
        let entries = try parser.parse()

        return entries.compactMap { item in
            guard item.isCollection,
                  let relative = relativePath(fromHref: item.href),
                  relative != normalized,
                  isImmediateChild(relative, of: normalized) else {
                return nil
            }

            return SMBDirectoryEntry(
                path: relative,
                name: (relative as NSString).lastPathComponent
            )
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func listRemoteMedia(at path: String) async throws -> [RemoteMediaEntry] {
        let normalized = normalize(path)
        let data = try await propfind(path: normalized, depth: "1")
        let entries = try WebDAVMultiStatusParser(data: data).parse()

        return entries.compactMap { item in
            guard let relative = relativePath(fromHref: item.href),
                  relative != normalized,
                  isImmediateChild(relative, of: normalized) else {
                return nil
            }

            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".filemann-") ||
                name.hasSuffix(".filemann-partial") ||
                name.hasSuffix(".partial") {
                return nil
            }

            let kind: RemoteMediaEntry.Kind
            if item.isCollection {
                kind = .folder
            } else if let type = UTType(filenameExtension: (name as NSString).pathExtension),
                      type.conforms(to: .image) {
                kind = .image
            } else if let type = UTType(filenameExtension: (name as NSString).pathExtension),
                      type.conforms(to: .movie) || type.conforms(to: .video) {
                kind = .video
            } else {
                kind = .other
            }

            return RemoteMediaEntry(
                path: relative,
                name: name,
                kind: kind,
                size: item.contentLength ?? 0,
                modifiedAt: item.modifiedAt
            )
        }
        .sorted { left, right in
            if left.kind == .folder && right.kind != .folder { return true }
            if left.kind != .folder && right.kind == .folder { return false }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func downloadRangeData(
        path: String,
        start: Int64,
        length: Int
    ) async throws -> Data {
        guard length > 0 else { return Data() }

        let lower = max(0, start)
        let upper = lower + Int64(length) - 1

        var request = URLRequest(
            url: remoteURL(for: path)
        )
        request.httpMethod = "GET"
        request.setValue(
            "bytes=\(lower)-\(upper)",
            forHTTPHeaderField: "Range"
        )
        applyAuthorization(to: &request)

        let (data, response) = try await session.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse else {
            throw WebDAVArchiveError.invalidResponse
        }

        if http.statusCode == 206 {
            return data.count > length
                ? Data(data.prefix(length))
                : data
        }

        if http.statusCode == 200, lower == 0 {
            return data.count > length
                ? Data(data.prefix(length))
                : data
        }

        throw WebDAVArchiveError.unexpectedStatus(
            http.statusCode
        )
    }

    func downloadData(path: String) async throws -> Data {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "GET"
        applyAuthorization(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    func downloadToTemporaryFile(path: String) async throws -> URL {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "GET"
        applyAuthorization(to: &request)

        let (url, response) = try await session.download(for: request)
        try validate(response)
        return url
    }

    func makeAuthorizedRequest(
        path: String,
        method: String = "GET",
        range: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = method
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        applyAuthorization(to: &request)
        return request
    }

    func desiredRemotePath(for task: ArchiveTask) -> String {
        let relative = (task.remoteRelativePath?.isEmpty == false)
            ? task.remoteRelativePath!
            : task.remoteFileName
        return join(settings.normalizedWebDAVDirectory, relative)
    }

    func prepareParentDirectory(for remotePath: String) async throws {
        let parent = (normalize(remotePath) as NSString).deletingLastPathComponent
        // Avoid one redundant PROPFIND per HEIC. The preflight already
        // verified the configured archive root is writable, and nested
        // directories only need to be created/checked once in this batch.
        if preparedUploadDirectories.contains(parent) {
            return
        }
        try await ensureDirectory(parent)
        preparedUploadDirectories.insert(parent)
    }

    func makeUploadRequest(
        path: String,
        failIfExists: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "PUT"
        request.timeoutInterval = 60 * 60 * 24
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        if failIfExists {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        applyAuthorization(to: &request)
        return request
    }

    func finalizeBackgroundUpload(
        partialPath: String,
        finalPath: String,
        expectedBytes: Int64,
        uploadMode: WebDAVUploadMode = .atomicMove
    ) async throws -> ArchiveResult {
        _ = try await verifyPublishedFile(
            at: partialPath,
            expectedBytes: expectedBytes
        )

        if uploadMode == .directPut {
            guard partialPath == finalPath else {
                throw WebDAVArchiveError.invalidResponse
            }
            return ArchiveResult(
                remoteSize: expectedBytes,
                remotePath: normalize(finalPath)
            )
        }

        if await remoteFileSize(atPath: finalPath) != nil {
            throw WebDAVArchiveError.remoteConflict(
                (finalPath as NSString).lastPathComponent
            )
        }

        var request = URLRequest(url: remoteURL(for: partialPath))
        request.httpMethod = "MOVE"
        request.setValue(
            remoteURL(for: finalPath).absoluteString,
            forHTTPHeaderField: "Destination"
        )
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        applyAuthorization(to: &request)

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 403 {
            throw WebDAVArchiveError.forbidden(
                operation: "重命名上传临时文件（MOVE）",
                path: finalPath
            )
        }
        try validate(response, accepted: [201, 204])

        return try await verifyPublishedFile(
            at: finalPath,
            expectedBytes: expectedBytes
        )
    }

    /// Verify visibility in the exact uploaded endpoint's *parent listing*.
    /// HEAD 200 and Content-Length alone are not evidence: a reverse proxy
    /// may return a fallback page or a stale object from a different share.
    /// This is intentionally read-only and never deletes or moves NAS data.
    func verifyPublishedFile(
        at path: String,
        expectedBytes: Int64
    ) async throws -> ArchiveResult {
        let file = normalize(path)
        guard !file.isEmpty else {
            throw WebDAVArchiveError.invalidResponse
        }
        let parent = (file as NSString).deletingLastPathComponent
        let listing = try await propfind(path: parent, depth: "1")
        let resources = try WebDAVMultiStatusParser(data: listing).parse()
        guard let actual = resources.first(where: { entry in
            guard !entry.isCollection,
                  let relative = relativePath(fromHref: entry.href) else {
                return false
            }
            return relative == file &&
                isImmediateChild(relative, of: parent)
        }) else {
            throw WebDAVArchiveError.remoteFileNotListed(
                remoteURL(for: file).absoluteString
            )
        }
        guard actual.contentLength == expectedBytes else {
            throw WebDAVArchiveError.remoteFileSizeMismatch(
                path: remoteURL(for: file).absoluteString,
                expected: expectedBytes,
                actual: actual.contentLength
            )
        }

        return ArchiveResult(
            remoteSize: expectedBytes,
            remotePath: file
        )
    }

    func findExactDuplicate(
        task: ArchiveTask,
        sourceURL: URL
    ) async throws -> RemoteFileInfo? {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart ||
                FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw WebDAVArchiveError.sourceUnavailable
        }

        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let currentSize = Int64(values.fileSize ?? 0)
        guard currentSize == task.fileSize else {
            throw WebDAVArchiveError.sourceChanged
        }

        if let originalModified = task.sourceModifiedAt,
           let currentModified = values.contentModificationDate,
           abs(currentModified.timeIntervalSince(originalModified)) > 1 {
            throw WebDAVArchiveError.sourceChanged
        }

        let inventory = try await remoteInventory()
        let candidates = inventory.filter { $0.size == task.fileSize }

        for candidate in candidates {
            try Task.checkCancellation()
            if try await exactCompare(
                sourceURL: sourceURL,
                remotePath: candidate.path,
                sourceAlreadyScoped: true
            ) {
                return candidate
            }
        }

        return nil
    }

    func verifyManifest(_ tasks: [ArchiveTask]) async -> BatchVerification {
        let expected = tasks.filter { $0.state != .skipped }
        let expectedCount = expected.count
        let expectedBytes = expected.reduce(Int64(0)) {
            $0 + $1.fileSize
        }
        var verifiedCount = 0
        var verifiedBytes: Int64 = 0

        for task in expected {
            guard task.state == .completed,
                  task.remoteEndpointURL == baseURLString,
                  let path = task.remoteVerifiedPath,
                  task.verifiedAt != nil,
                  let file = try? await verifyPublishedFile(
                    at: path,
                    expectedBytes: task.fileSize
                  ) else {
                continue
            }
            verifiedCount += 1
            verifiedBytes += file.remoteSize
        }

        return BatchVerification(
            expectedCount: expectedCount,
            expectedBytes: expectedBytes,
            verifiedCount: verifiedCount,
            verifiedBytes: verifiedBytes,
            checkedAt: Date()
        )
    }

    func deleteRemoteFile(at path: String) async throws {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "DELETE"
        applyAuthorization(to: &request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVArchiveError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) ||
                http.statusCode == 404 else {
            throw WebDAVArchiveError.unexpectedStatus(http.statusCode)
        }
        cachedRemoteInventory = nil
    }

    func deleteSourceFile(at url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart ||
                FileManager.default.fileExists(atPath: url.path) else {
            throw WebDAVArchiveError.sourceUnavailable
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deletionError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                FileMannShared.removeCompanionFiles(for: coordinatedURL)
            } catch {
                deletionError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let deletionError {
            throw deletionError
        }
    }

    func remoteFileSize(atPath path: String) async -> Int64? {
        do {
            var request = URLRequest(url: remoteURL(for: path))
            request.httpMethod = "HEAD"
            applyAuthorization(to: &request)

            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let value = http.value(
                    forHTTPHeaderField: "Content-Length"
               ),
               let size = Int64(value) {
                return size
            }
        } catch {
            // Fall back to PROPFIND below.
        }

        do {
            let data = try await propfind(path: path, depth: "0")
            let parser = WebDAVMultiStatusParser(data: data)
            return try parser.parse()
                .first(where: { !$0.isCollection })?
                .contentLength
        } catch {
            return nil
        }
    }

    private func remoteInventory() async throws -> [RemoteFileInfo] {
        if let cachedRemoteInventory {
            return cachedRemoteInventory
        }

        // QNAP / Apache WebDAV may reject Depth: infinity (HTTP 403)
        // even when Depth: 0 and Depth: 1 both work. Walk one directory
        // at a time and reuse the inventory across the batch.
        let root = settings.normalizedWebDAVDirectory
        var pending = [root]
        var visited = Set<String>()
        var files: [RemoteFileInfo] = []

        while let directory = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(directory).inserted else { continue }

            let data: Data
            do {
                data = try await propfind(path: directory, depth: "1")
            } catch WebDAVArchiveError.unexpectedStatus(let status)
                where (status == 403 || status == 404) && directory != root {
                // A folder can be hidden from this account while sibling
                // folders remain writable. Do not fail the entire upload.
                continue
            }
            let entries = try WebDAVMultiStatusParser(data: data).parse()

            for item in entries {
                guard let relative = relativePath(fromHref: item.href),
                      relative != directory,
                      isImmediateChild(relative, of: directory) else {
                    continue
                }

                if item.isCollection {
                    pending.append(relative)
                } else if let size = item.contentLength,
                          !relative.hasSuffix(".filemann-partial"),
                          !relative.contains(".filemann-") {
                    files.append(RemoteFileInfo(
                        path: relative,
                        name: (relative as NSString).lastPathComponent,
                        size: size
                    ))
                }
            }
        }

        cachedRemoteInventory = files
        return files
    }

    private func exactCompare(
        sourceURL: URL,
        remotePath: String,
        sourceAlreadyScoped: Bool
    ) async throws -> Bool {
        var didStart = false
        if !sourceAlreadyScoped {
            didStart = sourceURL.startAccessingSecurityScopedResource()
        }
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        var request = URLRequest(url: remoteURL(for: remotePath))
        request.httpMethod = "GET"
        applyAuthorization(to: &request)

        let (temporaryURL, response) = try await session.download(
            for: request
        )
        try validate(response)

        let local = try FileHandle(forReadingFrom: sourceURL)
        let remote = try FileHandle(forReadingFrom: temporaryURL)
        defer {
            try? local.close()
            try? remote.close()
        }

        let chunkSize = 4 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            let a = try local.read(upToCount: chunkSize) ?? Data()
            let b = try remote.read(upToCount: chunkSize) ?? Data()
            if a != b { return false }
            if a.isEmpty { return true }
        }
    }

    private func propfind(
        path: String,
        depth: String
    ) async throws -> Data {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue(
            "application/xml; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getcontenttype/>
            <d:displayname/>
          </d:prop>
        </d:propfind>
        """.utf8)
        applyAuthorization(to: &request)

        let (data, response) = try await session.data(for: request)
        try validate(response, accepted: [200, 207])
        return data
    }

    private func ensureDirectory(_ path: String) async throws {
        let normalized = normalize(path)
        guard !normalized.isEmpty else { return }

        // Some NAS shares allow direct access to the selected destination
        // but forbid browsing its parent folders. A parent-first PROPFIND
        // would incorrectly fail with HTTP 403 even when the final folder
        // is writable. Probe the exact destination first.
        if try await remoteExists(atPath: normalized) {
            return
        }

        var current = ""
        for component in normalized
            .split(separator: "/")
            .map(String.init) {
            current = current.isEmpty
                ? component
                : "\(current)/\(component)"

            if try await remoteExists(atPath: current) {
                continue
            }

            var request = URLRequest(url: remoteURL(for: current))
            request.httpMethod = "MKCOL"
            applyAuthorization(to: &request)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebDAVArchiveError.invalidResponse
            }

            if http.statusCode == 403 {
                throw WebDAVArchiveError.forbidden(
                    operation: "创建目录（MKCOL）",
                    path: remoteURL(for: current).path
                )
            }

            guard [200, 201, 204, 405]
                .contains(http.statusCode) else {
                throw WebDAVArchiveError.unexpectedStatus(
                    http.statusCode
                )
            }
        }
    }

    private func remoteExists(atPath path: String) async throws -> Bool {
        do {
            _ = try await propfind(path: path, depth: "0")
            return true
        } catch WebDAVArchiveError.unexpectedStatus(let status)
            where status == 404 {
            return false
        } catch WebDAVArchiveError.unexpectedStatus(let status)
            where status == 403 {
            throw WebDAVArchiveError.forbidden(
                operation: "读取归档目录（PROPFIND）",
                path: path
            )
        }
    }

    private func remoteURL(for path: String) -> URL {
        var url = baseURL
        for component in normalize(path)
            .split(separator: "/")
            .map(String.init) {
            url.appendPathComponent(component)
        }
        return url
    }

    private func relativePath(fromHref href: String) -> String? {
        let rawPath: String
        if let absolute = URL(string: href),
           absolute.scheme != nil {
            rawPath = absolute.path
        } else {
            rawPath = URL(
                string: href,
                relativeTo: baseURL
            )?.path ?? href
        }

        // URL.path already decodes the escaped href. Decoding a second
        // time changes a literal "%20" in an original filename to a
        // space and makes exact-name verification fail.
        let decoded = rawPath
        let root = baseURL.path
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        let value = decoded
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )

        if root.isEmpty {
            return normalize(value)
        }

        if value == root {
            return ""
        }

        guard value.hasPrefix(root + "/") else {
            return nil
        }

        return normalize(
            String(value.dropFirst(root.count + 1))
        )
    }

    private func isImmediateChild(
        _ child: String,
        of parent: String
    ) -> Bool {
        let c = normalize(child)
        let p = normalize(parent)

        if p.isEmpty {
            return !c.isEmpty && !c.contains("/")
        }

        guard c.hasPrefix(p + "/") else { return false }
        let remainder = String(
            c.dropFirst(p.count + 1)
        )
        return !remainder.isEmpty &&
            !remainder.contains("/")
    }

    private func applyAuthorization(
        to request: inout URLRequest
    ) {
        guard !settings.webDAVUsername.isEmpty else { return }
        let token = Data(
            "\(settings.webDAVUsername):\(password)".utf8
        ).base64EncodedString()

        request.setValue(
            "Basic \(token)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private func validate(
        _ response: URLResponse,
        accepted: Set<Int>? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVArchiveError.invalidResponse
        }

        if let accepted {
            guard accepted.contains(http.statusCode) else {
                throw WebDAVArchiveError.unexpectedStatus(
                    http.statusCode
                )
            }
        } else {
            guard (200...299).contains(http.statusCode) else {
                throw WebDAVArchiveError.unexpectedStatus(
                    http.statusCode
                )
            }
        }
    }

    private func normalize(_ value: String) -> String {
        // Only remove path separators, not user filename whitespace.
        // The archive must not silently change "clip .MOV" to "clip.MOV".
        value.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    private func join(
        _ left: String,
        _ right: String
    ) -> String {
        let l = normalize(left)
        let r = normalize(right)

        if l.isEmpty { return r }
        if r.isEmpty { return l }
        return "\(l)/\(r)"
    }
}

private struct WebDAVParsedEntry {
    var href: String = ""
    var contentLength: Int64?
    var modifiedAt: Date?
    var contentType: String?
    var isCollection = false
}

private final class WebDAVMultiStatusParser:
    NSObject,
    XMLParserDelegate {

    private let data: Data
    private var entries: [WebDAVParsedEntry] = []
    private var current: WebDAVParsedEntry?
    private var textBuffer = ""
    private var parseError: Error?

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> [WebDAVParsedEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            throw parser.parserError
                ?? parseError
                ?? WebDAVArchiveError.invalidResponse
        }

        return entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        let local = elementName.lowercased()
        textBuffer = ""

        if local.hasSuffix("response") {
            current = WebDAVParsedEntry()
        } else if local.hasSuffix("collection") {
            current?.isCollection = true
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = elementName.lowercased()
        let value = textBuffer
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if local.hasSuffix("href") {
            current?.href = value
        } else if local.hasSuffix("getcontentlength") {
            current?.contentLength = Int64(value)
        } else if local.hasSuffix("getcontenttype") {
            current?.contentType = value
        } else if local.hasSuffix("getlastmodified") {
            current?.modifiedAt = Self.httpDateFormatter.date(
                from: value
            )
        } else if local.hasSuffix("response") {
            if let current {
                entries.append(current)
            }
            current = nil
        }

        textBuffer = ""
    }

    func parser(
        _ parser: XMLParser,
        parseErrorOccurred parseError: Error
    ) {
        self.parseError = parseError
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
