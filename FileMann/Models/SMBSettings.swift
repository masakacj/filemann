import Foundation

enum ArchiveTransport: String, Codable, CaseIterable, Identifiable {
    case webDAV
    case smb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webDAV: return "QNAP WebDAV"
        case .smb: return "SMB 兼容模式"
        }
    }
}

struct SMBSettings: Codable, Equatable {
    var transport: ArchiveTransport = .webDAV

    // Legacy full URLs are preserved for migration only.
    var webDAVBaseURL: String = ""
    var webDAVRemoteBaseURL: String = ""

    // WebDAV connection-style input.
    var webDAVLocalTitle: String = "本地 NAS"
    var webDAVLocalHost: String = ""
    var webDAVLocalPort: String = ""
    var webDAVLocalPath: String = "/"
    var webDAVLocalHTTPS: Bool = true

    var webDAVRemoteTitle: String = "远程 NAS"
    var webDAVRemoteHost: String = ""
    var webDAVRemotePort: String = ""
    var webDAVRemotePath: String = "/"
    var webDAVRemoteHTTPS: Bool = true

    // Same NAS account is shared by local and remote endpoints.
    var webDAVUsername: String = ""
    var webDAVRemoteDirectory: String = ""
    var webDAVWiFiOnly: Bool = false
    var webDAVBackgroundTransfers: Bool = true

    // SMB fallback.
    var host: String = ""
    var share: String = ""
    var remoteDirectory: String = ""
    var username: String = ""
    var chunkSizeMB: Int = 16

    var deleteAfterArchive: Bool = true

    var normalizedHost: String {
        host
            .replacingOccurrences(
                of: "smb://",
                with: "",
                options: [.caseInsensitive]
            )
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/ ")
            )
    }

    var normalizedShare: String {
        share.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
        )
    }

    var normalizedDirectory: String {
        remoteDirectory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
        )
    }

    var normalizedWebDAVDirectory: String {
        webDAVRemoteDirectory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
        )
    }

    var normalizedWebDAVBaseURL: String {
        let composed = Self.composeWebDAVURL(
            host: webDAVLocalHost,
            port: webDAVLocalPort,
            path: webDAVLocalPath,
            https: webDAVLocalHTTPS
        )
        return composed.isEmpty
            ? normalizeWebDAVAddress(webDAVBaseURL)
            : composed
    }

    var normalizedWebDAVRemoteBaseURL: String {
        let composed = Self.composeWebDAVURL(
            host: webDAVRemoteHost,
            port: webDAVRemotePort,
            path: webDAVRemotePath,
            https: webDAVRemoteHTTPS
        )
        return composed.isEmpty
            ? normalizeWebDAVAddress(webDAVRemoteBaseURL)
            : composed
    }

    var webDAVCandidateBaseURLs: [String] {
        var values: [String] = []

        for value in [
            normalizedWebDAVBaseURL,
            normalizedWebDAVRemoteBaseURL
        ] where !value.isEmpty && !values.contains(value) {
            values.append(value)
        }

        return values
    }

    var activeRemoteDirectory: String {
        switch transport {
        case .webDAV:
            return normalizedWebDAVDirectory
        case .smb:
            return normalizedDirectory
        }
    }

    var isValid: Bool {
        switch transport {
        case .webDAV:
            return webDAVCandidateBaseURLs.contains(
                where: Self.isValidWebDAVURL
            )
        case .smb:
            return !normalizedHost.isEmpty &&
                !normalizedShare.isEmpty
        }
    }

    func webDAVTitle(
        for baseURLString: String
    ) -> String {
        let normalized = normalizeWebDAVAddress(
            baseURLString
        )

        if normalized == normalizedWebDAVBaseURL {
            let title = webDAVLocalTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "本地 NAS" : title
        }

        if normalized == normalizedWebDAVRemoteBaseURL {
            let title = webDAVRemoteTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "远程 NAS" : title
        }

        return "NAS"
    }

    static func isValidWebDAVURL(
        _ value: String
    ) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }

        return true
    }

    private static func composeWebDAVURL(
        host: String,
        port: String,
        path: String,
        https: Bool
    ) -> String {
        let cleanHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "https://",
                with: "",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(
                of: "http://",
                with: "",
                options: [.caseInsensitive]
            )
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )

        guard !cleanHost.isEmpty else {
            return ""
        }

        var result = "\(https ? "https" : "http")://\(cleanHost)"

        let cleanPort = port
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPort.isEmpty {
            result += ":\(cleanPort)"
        }

        let cleanPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanPath.isEmpty && cleanPath != "/" {
            result += "/"
            result += cleanPath.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }

        return result
    }

    private func normalizeWebDAVAddress(
        _ value: String
    ) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
    }

    private static func parseLegacyURL(
        _ value: String
    ) -> (
        host: String,
        port: String,
        path: String,
        https: Bool
    )? {
        guard let url = URL(string: value),
              let host = url.host,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return (
            host,
            url.port.map(String.init) ?? "",
            url.path.isEmpty ? "/" : url.path,
            scheme == "https"
        )
    }

    enum CodingKeys: String, CodingKey {
        case transport
        case webDAVBaseURL
        case webDAVRemoteBaseURL

        case webDAVLocalTitle
        case webDAVLocalHost
        case webDAVLocalPort
        case webDAVLocalPath
        case webDAVLocalHTTPS

        case webDAVRemoteTitle
        case webDAVRemoteHost
        case webDAVRemotePort
        case webDAVRemotePath
        case webDAVRemoteHTTPS

        case webDAVRemoteDirectory
        case webDAVUsername
        case webDAVWiFiOnly
        case webDAVBackgroundTransfers

        case host
        case share
        case remoteDirectory
        case username
        case chunkSizeMB

        case deleteAfterArchive
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(
            keyedBy: CodingKeys.self
        )

        transport = try c.decodeIfPresent(
            ArchiveTransport.self,
            forKey: .transport
        ) ?? .webDAV

        webDAVBaseURL = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVBaseURL
        ) ?? ""

        webDAVRemoteBaseURL = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemoteBaseURL
        ) ?? ""

        webDAVLocalTitle = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVLocalTitle
        ) ?? "本地 NAS"

        webDAVLocalHost = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVLocalHost
        ) ?? ""

        webDAVLocalPort = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVLocalPort
        ) ?? ""

        webDAVLocalPath = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVLocalPath
        ) ?? "/"

        webDAVLocalHTTPS = try c.decodeIfPresent(
            Bool.self,
            forKey: .webDAVLocalHTTPS
        ) ?? true

        webDAVRemoteTitle = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemoteTitle
        ) ?? "远程 NAS"

        webDAVRemoteHost = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemoteHost
        ) ?? ""

        webDAVRemotePort = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemotePort
        ) ?? ""

        webDAVRemotePath = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemotePath
        ) ?? "/"

        webDAVRemoteHTTPS = try c.decodeIfPresent(
            Bool.self,
            forKey: .webDAVRemoteHTTPS
        ) ?? true

        webDAVRemoteDirectory = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVRemoteDirectory
        ) ?? ""

        webDAVUsername = try c.decodeIfPresent(
            String.self,
            forKey: .webDAVUsername
        ) ?? ""

        webDAVWiFiOnly = try c.decodeIfPresent(
            Bool.self,
            forKey: .webDAVWiFiOnly
        ) ?? false

        webDAVBackgroundTransfers = try c.decodeIfPresent(
            Bool.self,
            forKey: .webDAVBackgroundTransfers
        ) ?? true

        host = try c.decodeIfPresent(
            String.self,
            forKey: .host
        ) ?? ""

        share = try c.decodeIfPresent(
            String.self,
            forKey: .share
        ) ?? ""

        remoteDirectory = try c.decodeIfPresent(
            String.self,
            forKey: .remoteDirectory
        ) ?? ""

        username = try c.decodeIfPresent(
            String.self,
            forKey: .username
        ) ?? ""

        chunkSizeMB = try c.decodeIfPresent(
            Int.self,
            forKey: .chunkSizeMB
        ) ?? 16

        deleteAfterArchive = try c.decodeIfPresent(
            Bool.self,
            forKey: .deleteAfterArchive
        ) ?? true

        if webDAVLocalHost.isEmpty,
           let legacy = Self.parseLegacyURL(
                webDAVBaseURL
           ) {
            webDAVLocalHost = legacy.host
            webDAVLocalPort = legacy.port
            webDAVLocalPath = legacy.path
            webDAVLocalHTTPS = legacy.https
        }

        if webDAVRemoteHost.isEmpty,
           let legacy = Self.parseLegacyURL(
                webDAVRemoteBaseURL
           ) {
            webDAVRemoteHost = legacy.host
            webDAVRemotePort = legacy.port
            webDAVRemotePath = legacy.path
            webDAVRemoteHTTPS = legacy.https
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(
            keyedBy: CodingKeys.self
        )

        try c.encode(transport, forKey: .transport)

        try c.encode(
            normalizedWebDAVBaseURL,
            forKey: .webDAVBaseURL
        )
        try c.encode(
            normalizedWebDAVRemoteBaseURL,
            forKey: .webDAVRemoteBaseURL
        )

        try c.encode(
            webDAVLocalTitle,
            forKey: .webDAVLocalTitle
        )
        try c.encode(
            webDAVLocalHost,
            forKey: .webDAVLocalHost
        )
        try c.encode(
            webDAVLocalPort,
            forKey: .webDAVLocalPort
        )
        try c.encode(
            webDAVLocalPath,
            forKey: .webDAVLocalPath
        )
        try c.encode(
            webDAVLocalHTTPS,
            forKey: .webDAVLocalHTTPS
        )

        try c.encode(
            webDAVRemoteTitle,
            forKey: .webDAVRemoteTitle
        )
        try c.encode(
            webDAVRemoteHost,
            forKey: .webDAVRemoteHost
        )
        try c.encode(
            webDAVRemotePort,
            forKey: .webDAVRemotePort
        )
        try c.encode(
            webDAVRemotePath,
            forKey: .webDAVRemotePath
        )
        try c.encode(
            webDAVRemoteHTTPS,
            forKey: .webDAVRemoteHTTPS
        )

        try c.encode(
            webDAVRemoteDirectory,
            forKey: .webDAVRemoteDirectory
        )
        try c.encode(
            webDAVUsername,
            forKey: .webDAVUsername
        )
        try c.encode(
            webDAVWiFiOnly,
            forKey: .webDAVWiFiOnly
        )
        try c.encode(
            webDAVBackgroundTransfers,
            forKey: .webDAVBackgroundTransfers
        )

        try c.encode(host, forKey: .host)
        try c.encode(share, forKey: .share)
        try c.encode(
            remoteDirectory,
            forKey: .remoteDirectory
        )
        try c.encode(username, forKey: .username)
        try c.encode(
            chunkSizeMB,
            forKey: .chunkSizeMB
        )

        try c.encode(
            deleteAfterArchive,
            forKey: .deleteAfterArchive
        )
    }
}
