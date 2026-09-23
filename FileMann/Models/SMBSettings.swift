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

    var webDAVBaseURL: String = ""
    var webDAVRemoteDirectory: String = ""
    var webDAVUsername: String = ""
    var webDAVWiFiOnly: Bool = true
    var webDAVBackgroundTransfers: Bool = true

    var host: String = ""
    var share: String = ""
    var remoteDirectory: String = ""
    var username: String = ""
    var chunkSizeMB: Int = 16

    var deleteAfterArchive: Bool = true

    var normalizedHost: String {
        host
            .replacingOccurrences(of: "smb://", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedShare: String {
        share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedDirectory: String {
        remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedWebDAVDirectory: String {
        webDAVRemoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedWebDAVBaseURL: String {
        webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var activeRemoteDirectory: String {
        switch transport {
        case .webDAV: return normalizedWebDAVDirectory
        case .smb: return normalizedDirectory
        }
    }

    var isValid: Bool {
        switch transport {
        case .webDAV:
            guard let url = URL(string: normalizedWebDAVBaseURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                return false
            }
            return true
        case .smb:
            return !normalizedHost.isEmpty && !normalizedShare.isEmpty
        }
    }

    enum CodingKeys: String, CodingKey {
        case transport
        case webDAVBaseURL
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decodeIfPresent(ArchiveTransport.self, forKey: .transport) ?? .webDAV
        webDAVBaseURL = try c.decodeIfPresent(String.self, forKey: .webDAVBaseURL) ?? ""
        webDAVRemoteDirectory = try c.decodeIfPresent(String.self, forKey: .webDAVRemoteDirectory) ?? ""
        webDAVUsername = try c.decodeIfPresent(String.self, forKey: .webDAVUsername) ?? ""
        webDAVWiFiOnly = try c.decodeIfPresent(Bool.self, forKey: .webDAVWiFiOnly) ?? true
        webDAVBackgroundTransfers = try c.decodeIfPresent(Bool.self, forKey: .webDAVBackgroundTransfers) ?? true
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        share = try c.decodeIfPresent(String.self, forKey: .share) ?? ""
        remoteDirectory = try c.decodeIfPresent(String.self, forKey: .remoteDirectory) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        chunkSizeMB = try c.decodeIfPresent(Int.self, forKey: .chunkSizeMB) ?? 16
        deleteAfterArchive = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterArchive) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transport, forKey: .transport)
        try c.encode(webDAVBaseURL, forKey: .webDAVBaseURL)
        try c.encode(webDAVRemoteDirectory, forKey: .webDAVRemoteDirectory)
        try c.encode(webDAVUsername, forKey: .webDAVUsername)
        try c.encode(webDAVWiFiOnly, forKey: .webDAVWiFiOnly)
        try c.encode(webDAVBackgroundTransfers, forKey: .webDAVBackgroundTransfers)
        try c.encode(host, forKey: .host)
        try c.encode(share, forKey: .share)
        try c.encode(remoteDirectory, forKey: .remoteDirectory)
        try c.encode(username, forKey: .username)
        try c.encode(chunkSizeMB, forKey: .chunkSizeMB)
        try c.encode(deleteAfterArchive, forKey: .deleteAfterArchive)
    }
}
