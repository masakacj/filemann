import Foundation

/// Personal configuration endpoint. Credentials are supplied at runtime and
/// are never embedded in the public repository or the IPA.
struct FileMannConfigEnvelope: Decodable {
    let schema: Int
    let app: String
    let config: FileMannRemoteConfig
}

struct FileMannRemoteConfig: Decodable {
    struct WebDAV: Decodable {
        var localURL: String?
        var remoteURL: String?
        var username: String?
        var password: String?
        var archiveDirectory: String?
        var wifiOnly: Bool?
        var allowInvalidLocalCertificate: Bool?
        var allowInvalidRemoteCertificate: Bool?
    }

    struct SMB: Decodable {
        var host: String?
        var share: String?
        var directory: String?
        var username: String?
        var password: String?
        var chunkSizeMB: Int?
    }

    struct Transfer: Decodable {
        var transport: String?
        var deleteAfterArchive: Bool?
    }

    var webdav: WebDAV?
    var smb: SMB?
    var transfer: Transfer?

    /// A partial server record updates only supplied keys. This permits
    /// migration before the private NAS secrets are provisioned centrally.
    func applying(to existing: SMBSettings) throws -> SMBSettings {
        var result = existing
        if let webdav {
            if let value = webdav.localURL {
                try Self.applyEndpoint(value, remote: false, to: &result)
            }
            if let value = webdav.remoteURL {
                try Self.applyEndpoint(value, remote: true, to: &result)
            }
            if let value = webdav.username {
                result.webDAVUsername = value
            }
            if let value = webdav.archiveDirectory {
                result.webDAVRemoteDirectory = value
            }
            if let value = webdav.wifiOnly {
                result.webDAVWiFiOnly = value
            }
            if let value = webdav.allowInvalidLocalCertificate {
                result.webDAVLocalAllowInvalidCertificate = value
            }
            if let value = webdav.allowInvalidRemoteCertificate {
                result.webDAVRemoteAllowInvalidCertificate = value
            }
        }
        if let smb {
            if let value = smb.host { result.host = value }
            if let value = smb.share { result.share = value }
            if let value = smb.directory { result.remoteDirectory = value }
            if let value = smb.username { result.username = value }
            if let value = smb.chunkSizeMB {
                guard (1...64).contains(value) else {
                    throw ConfigCenterError.invalidConfiguration
                }
                result.chunkSizeMB = value
            }
        }
        if let transfer {
            if let value = transfer.transport {
                guard let selected = ArchiveTransport(rawValue: value) else {
                    throw ConfigCenterError.invalidConfiguration
                }
                result.transport = selected
            }
            if let value = transfer.deleteAfterArchive {
                result.deleteAfterArchive = value
            }
        }
        return result
    }

    private static func applyEndpoint(
        _ value: String,
        remote: Bool,
        to settings: inout SMBSettings
    ) throws {
        if value.isEmpty {
            if remote {
                settings.webDAVRemoteHost = ""
                settings.webDAVRemoteBaseURL = ""
                settings.webDAVRemotePort = ""
                settings.webDAVRemotePath = "/"
            }
            return
        }
        guard let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              (!remote || scheme == "https") else {
            throw ConfigCenterError.invalidConfiguration
        }

        if remote {
            settings.webDAVRemoteHost = host
            settings.webDAVRemotePort = url.port.map(String.init) ?? ""
            settings.webDAVRemotePath = url.percentEncodedPath.isEmpty
                ? "/" : url.percentEncodedPath
            settings.webDAVRemoteHTTPS = scheme == "https"
            settings.webDAVRemoteBaseURL = ""
        } else {
            settings.webDAVLocalHost = host
            settings.webDAVLocalPort = url.port.map(String.init) ?? ""
            settings.webDAVLocalPath = url.percentEncodedPath.isEmpty
                ? "/" : url.percentEncodedPath
            settings.webDAVLocalHTTPS = scheme == "https"
            settings.webDAVBaseURL = ""
        }
    }
}

enum ConfigCenterError: LocalizedError {
    case missingPassword
    case incorrectPassword
    case missingApp
    case temporarilyLimited
    case invalidConfiguration
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingPassword: return "请输入配置中心固定密码"
        case .incorrectPassword: return "配置中心密码不正确"
        case .missingApp: return "配置中心还没有 filemann 的配置记录"
        case .temporarilyLimited: return "配置中心暂时限制尝试次数"
        case .invalidConfiguration: return "FileMann 配置格式或外网 HTTPS 地址无效"
        case .unexpectedResponse: return "配置中心返回了无法识别的响应"
        }
    }
}

enum ConfigCenterClient {
    static let appID = "filemann"
    static let endpoint = URL(
        string: "https://config.781751.xyz:58443/v1/config/filemann"
    )!

    static func fetch(password: String) async throws -> FileMannRemoteConfig {
        guard !password.isEmpty else {
            throw ConfigCenterError.missingPassword
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(["password": password])

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConfigCenterError.unexpectedResponse
        }
        switch http.statusCode {
        case 200: break
        case 403: throw ConfigCenterError.incorrectPassword
        case 404: throw ConfigCenterError.missingApp
        case 429: throw ConfigCenterError.temporarilyLimited
        default: throw ConfigCenterError.unexpectedResponse
        }

        let envelope = try JSONDecoder().decode(
            FileMannConfigEnvelope.self, from: data
        )
        guard envelope.schema == 1, envelope.app == appID else {
            throw ConfigCenterError.invalidConfiguration
        }
        return envelope.config
    }
}
