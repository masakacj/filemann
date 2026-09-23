import Foundation
import UniformTypeIdentifiers

enum WebDAVArchiveError: LocalizedError {
    case invalidBaseURL
    case noReachableEndpoint
    case unexpectedStatus(Int)
    case remoteConflict(String)
    case remoteVerificationFailed
    case sourceUnavailable
    case sourceChanged
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "WebDAV 地址无效"
        case .noReachableEndpoint:
            return "本地和远程 WebDAV 地址都无法连接"
        case .unexpectedStatus(let code):
            return "WebDAV 返回 HTTP \(code)"
        case .remoteConflict(let name):
            return "NAS 上已存在同路径文件：\(name)"
        case .remoteVerificationFailed:
            return "NAS 文件大小校验失败"
        case .sourceUnavailable:
            return "无法访问源文件"
        case .sourceChanged:
            return "源文件已发生变化，请重新加入任务"
        case .invalidResponse:
            return "WebDAV 返回内容无法解析"
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
    private let session: URLSession
    private let baseURL: URL

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

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.allowsCellularAccess = !settings.webDAVWiFiOnly
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
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
                    allowsCellular: !settings.webDAVWiFiOnly
                )
                return candidate
            } catch {
                lastError = error
            }
        }

        throw lastError ?? WebDAVArchiveError.noReachableEndpoint
    }

    private static func probe(
        baseURLString: String,
        username: String,
        password: String,
        timeout: TimeInterval,
        allowsCellular: Bool
    ) async throws {
        guard let url = URL(string: baseURLString) else {
            throw WebDAVArchiveError.invalidBaseURL
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.allowsCellularAccess = allowsCellular
        let session = URLSession(configuration: config)

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

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVArchiveError.invalidResponse
        }
        guard [200, 207].contains(http.statusCode) else {
            throw WebDAVArchiveError.unexpectedStatus(http.statusCode)
        }
    }

    func connectAndPrepare() async throws {
        _ = try await propfind(path: "", depth: "0")
        try await ensureDirectory(settings.normalizedWebDAVDirectory)
    }

    func testConnection() async throws {
        try await connectAndPrepare()
        _ = try await propfind(
            path: settings.normalizedWebDAVDirectory,
            depth: "0"
        )
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
        try await ensureDirectory(parent)
    }

    func makeUploadRequest(path: String) throws -> URLRequest {
        var request = URLRequest(url: remoteURL(for: path))
        request.httpMethod = "PUT"
        request.timeoutInterval = 60 * 60 * 24
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        applyAuthorization(to: &request)
        return request
    }

    func finalizeBackgroundUpload(
        partialPath: String,
        finalPath: String,
        expectedBytes: Int64
    ) async throws -> ArchiveResult {
        guard await remoteFileSize(atPath: partialPath) == expectedBytes else {
            throw WebDAVArchiveError.remoteVerificationFailed
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
        try validate(response, accepted: [201, 204])

        guard await remoteFileSize(atPath: finalPath) == expectedBytes else {
            throw WebDAVArchiveError.remoteVerificationFailed
        }

        return ArchiveResult(
            remoteSize: expectedBytes,
            remotePath: normalize(finalPath)
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
            let path = task.remoteVerifiedPath
                ?? desiredRemotePath(for: task)
            if let size = await remoteFileSize(atPath: path),
               size == task.fileSize {
                verifiedCount += 1
                verifiedBytes += size
            }
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
        let root = settings.normalizedWebDAVDirectory
        let data = try await propfind(path: root, depth: "infinity")
        let values = try WebDAVMultiStatusParser(data: data).parse()

        return values.compactMap { item in
            guard !item.isCollection,
                  let size = item.contentLength,
                  let relative = relativePath(fromHref: item.href),
                  !relative.hasSuffix(".filemann-partial"),
                  !relative.contains(".filemann-") else {
                return nil
            }

            return RemoteFileInfo(
                path: relative,
                name: (relative as NSString).lastPathComponent,
                size: size
            )
        }
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

        var current = ""
        for component in normalized
            .split(separator: "/")
            .map(String.init) {
            current = current.isEmpty
                ? component
                : "\(current)/\(component)"

            if await remoteExists(atPath: current) {
                continue
            }

            var request = URLRequest(url: remoteURL(for: current))
            request.httpMethod = "MKCOL"
            applyAuthorization(to: &request)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebDAVArchiveError.invalidResponse
            }

            guard [200, 201, 204, 405]
                .contains(http.statusCode) else {
                throw WebDAVArchiveError.unexpectedStatus(
                    http.statusCode
                )
            }
        }
    }

    private func remoteExists(atPath path: String) async -> Bool {
        do {
            _ = try await propfind(path: path, depth: "0")
            return true
        } catch {
            return false
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

        let decoded = rawPath.removingPercentEncoding ?? rawPath
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
        value.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
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
