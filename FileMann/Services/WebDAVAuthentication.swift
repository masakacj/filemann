import Foundation
import Security

enum WebDAVChallengeHandler {
    static func handle(
        challenge: URLAuthenticationChallenge,
        username: String,
        password: String,
        allowInvalidCertificate: Bool,
        trustedHost: String?,
        trustedPort: Int?,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let method = protectionSpace.authenticationMethod

        let hostMatches: Bool = {
            guard let trustedHost else { return false }
            guard trustedHost.caseInsensitiveCompare(
                protectionSpace.host
            ) == .orderedSame else {
                return false
            }

            guard let trustedPort else { return true }
            return trustedPort == protectionSpace.port
        }()

        if method == NSURLAuthenticationMethodServerTrust {
            if allowInvalidCertificate,
               hostMatches,
               let trust = protectionSpace.serverTrust {
                completionHandler(
                    .useCredential,
                    URLCredential(trust: trust)
                )
            } else {
                completionHandler(
                    .performDefaultHandling,
                    nil
                )
            }
            return
        }

        let passwordMethods: Set<String> = [
            NSURLAuthenticationMethodDefault,
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM
        ]

        if passwordMethods.contains(method),
           hostMatches,
           challenge.previousFailureCount == 0,
           !username.isEmpty {
            completionHandler(
                .useCredential,
                URLCredential(
                    user: username,
                    password: password,
                    persistence: .forSession
                )
            )
            return
        }

        completionHandler(
            .performDefaultHandling,
            nil
        )
    }

    static func endpoint(
        from urlString: String
    ) -> (
        host: String?,
        port: Int?
    ) {
        guard let url = URL(string: urlString) else {
            return (nil, nil)
        }

        let scheme = url.scheme?.lowercased()
        let port = url.port
            ?? (scheme == "https" ? 443 : 80)

        return (url.host, port)
    }
}

final class WebDAVSessionDelegate:
    NSObject,
    URLSessionDelegate,
    URLSessionTaskDelegate {

    private let username: String
    private let password: String
    private let allowInvalidCertificate: Bool
    private let trustedHost: String?
    private let trustedPort: Int?

    init(
        username: String,
        password: String,
        allowInvalidCertificate: Bool,
        baseURLString: String
    ) {
        self.username = username
        self.password = password
        self.allowInvalidCertificate = allowInvalidCertificate

        let endpoint = WebDAVChallengeHandler.endpoint(
            from: baseURLString
        )
        self.trustedHost = endpoint.host
        self.trustedPort = endpoint.port

        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        WebDAVChallengeHandler.handle(
            challenge: challenge,
            username: username,
            password: password,
            allowInvalidCertificate:
                allowInvalidCertificate,
            trustedHost: trustedHost,
            trustedPort: trustedPort,
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
        WebDAVChallengeHandler.handle(
            challenge: challenge,
            username: username,
            password: password,
            allowInvalidCertificate:
                allowInvalidCertificate,
            trustedHost: trustedHost,
            trustedPort: trustedPort,
            completionHandler: completionHandler
        )
    }
}
