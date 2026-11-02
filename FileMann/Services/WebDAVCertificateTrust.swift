import CryptoKit
import Foundation
import Security

/// An explicit certificate identity pin for one NAS HTTPS host and port.
/// Unlike a "trust all" SSL switch, any renewed or intercepted certificate
/// must be checked again against a separately verified fingerprint.
enum WebDAVCertificateTrust {
    enum PinError: LocalizedError {
        case invalidIdentity
        case invalidFingerprint

        var errorDescription: String? {
            switch self {
            case .invalidIdentity:
                return "证书主机或端口无效"
            case .invalidFingerprint:
                return "证书 SHA-256 指纹必须为 64 位十六进制"
            }
        }
    }

    private static let service = "com.masakacj.filemann.webdav.certificates"

    static func fingerprint(_ certificate: SecCertificate) -> String {
        let bytes = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: bytes).map {
            String(format: "%02X", $0)
        }.joined()
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            return nil
        }
        return fingerprint(certificate)
    }

    static func normalizeFingerprint(_ value: String) -> String? {
        let text = value.uppercased()
            .filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard text.count == 64,
              text.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0)
              }) else {
            return nil
        }
        return text
    }

    private static func account(host: String, port: Int) -> String? {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !clean.isEmpty, !clean.contains("/"),
              !clean.contains("@"), (1...65535).contains(port) else {
            return nil
        }
        return "\(clean):\(port)"
    }

    private static func query(host: String, port: Int) -> [String: Any]? {
        guard let account = account(host: host, port: port) else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func pinnedFingerprint(host: String, port: Int) -> String? {
        guard var request = query(host: host, port: port) else { return nil }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result)
                == errSecSuccess,
              let bytes = result as? Data,
              let value = String(data: bytes, encoding: .utf8) else {
            return nil
        }
        return normalizeFingerprint(value)
    }

    static func matches(trust: SecTrust, host: String, port: Int) -> Bool {
        guard let expected = pinnedFingerprint(host: host, port: port),
              let actual = fingerprint(of: trust) else { return false }
        return expected == actual
    }

    static func save(_ fingerprint: String, host: String, port: Int) throws {
        guard let valid = normalizeFingerprint(fingerprint) else {
            throw PinError.invalidFingerprint
        }
        guard let base = query(host: host, port: port) else {
            throw PinError.invalidIdentity
        }
        var item = base
        item[kSecValueData as String] = Data(valid.utf8)
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemDelete(base as CFDictionary)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func remove(host: String, port: Int) {
        guard let base = query(host: host, port: port) else { return }
        SecItemDelete(base as CFDictionary)
    }
}

struct WebDAVCertificateInspection: Sendable {
    let host: String
    let port: Int
    let subject: String
    let fingerprint: String
    let systemTrusted: Bool
    let reason: String

    var formattedFingerprint: String {
        let s = Array(fingerprint)
        return stride(from: 0, to: s.count, by: 2)
            .map { String(s[$0..<min($0 + 2, s.count)]) }
            .joined(separator: ":")
    }
}

/// Read-only TLS identity inspection. It sends no NAS credentials, performs
/// no trust override, and never follows an HTTP redirect to another origin.
enum WebDAVCertificateInspector {
    enum InspectError: LocalizedError {
        case invalidAddress
        case noCertificate

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return "请先填写有效的 HTTPS 远程地址"
            case .noCertificate:
                return "服务器未提供可检查的 TLS 证书；请确认端口和 HTTPS 配置"
            }
        }
    }

    static func inspect(urlString: String) async throws
        -> WebDAVCertificateInspection {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            throw InspectError.invalidAddress
        }

        let inspector = WebDAVCertificateInspectorDelegate(
            host: host, port: url.port ?? 443
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false

        let session = URLSession(
            configuration: configuration,
            delegate: inspector,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Even an untrusted certificate is captured during the TLS challenge
        // before the system refuses the request. HTTP 401/404 is acceptable.
        _ = try? await session.data(for: request)

        guard let inspection = inspector.snapshot else {
            throw InspectError.noCertificate
        }
        return inspection
    }
}

private final class WebDAVCertificateInspectorDelegate:
    NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var lastInspection: WebDAVCertificateInspection?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var snapshot: WebDAVCertificateInspection? {
        lock.lock()
        defer { lock.unlock() }
        return lastInspection
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust,
              space.host.caseInsensitiveCompare(host) == .orderedSame,
              space.port == port,
              let trust = space.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var underlying: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &underlying)
        let subject = SecCertificateCopySubjectSummary(certificate)
            as String? ?? "(未知主体)"
        let inspection = WebDAVCertificateInspection(
            host: host,
            port: port,
            subject: subject,
            fingerprint: WebDAVCertificateTrust.fingerprint(certificate),
            systemTrusted: trusted,
            reason: trusted ? "iOS 系统证书验证通过" :
                (underlying?.localizedDescription ??
                 "证书链、有效期或主机名未通过 iOS 系统验证")
        )
        lock.lock()
        lastInspection = inspection
        lock.unlock()
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
