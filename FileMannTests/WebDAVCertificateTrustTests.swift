import Foundation
import XCTest
@testable import FileMann

final class WebDAVCertificateTrustTests: XCTestCase {
    func testFingerprintNormalizationAndStrictScope() throws {
        let sample = String(repeating: "AB", count: 32)
        XCTAssertEqual(
            WebDAVCertificateTrust.normalizeFingerprint(
                sample.lowercased()
            ),
            sample
        )
        XCTAssertEqual(
            WebDAVCertificateTrust.normalizeFingerprint(
                sample.enumerated().map {
                    $0.offset % 2 == 0 ? String($0.element) : String($0.element) + ":"
                }.joined()
            ),
            sample
        )
        XCTAssertNil(WebDAVCertificateTrust.normalizeFingerprint("not-a-hash"))
        XCTAssertNil(WebDAVCertificateTrust.normalizeFingerprint(
            String(repeating: "Z", count: 64)
        ))

        let host = "filemann-pin-test.example"
        defer {
            WebDAVCertificateTrust.remove(host: host, port: 8443)
        }
        try WebDAVCertificateTrust.save(
            sample, host: host.uppercased(), port: 8443
        )
        XCTAssertEqual(
            WebDAVCertificateTrust.pinnedFingerprint(
                host: host, port: 8443
            ),
            sample
        )
        XCTAssertNil(WebDAVCertificateTrust.pinnedFingerprint(
            host: host, port: 443
        ))
        XCTAssertNil(WebDAVCertificateTrust.pinnedFingerprint(
            host: "other.example", port: 8443
        ))
    }

    func testTrustStoreRejectsInvalidCertificates() {
        XCTAssertThrowsError(
            try WebDAVCertificateTrust.save(
                "bad", host: "nas.example", port: 443
            )
        )
        XCTAssertThrowsError(
            try WebDAVCertificateTrust.save(
                String(repeating: "A", count: 64),
                host: "", port: 443
            )
        )
    }

    func testReadOnlyInspectionOfSystemTrustedMock() async throws {
        let cert = try await WebDAVCertificateInspector.inspect(
            urlString: "https://127.0.0.1:8766/"
        )
        XCTAssertEqual(cert.host, "127.0.0.1")
        XCTAssertEqual(cert.port, 8766)
        XCTAssertEqual(cert.fingerprint.count, 64)
        XCTAssertTrue(cert.systemTrusted, cert.reason)
    }

    func testExplicitPinAllowsOnlySameUntrustedNASCertificate()
        async throws {
        let host = "127.0.0.1"
        let port = 8767
        WebDAVCertificateTrust.remove(host: host, port: port)
        defer { WebDAVCertificateTrust.remove(host: host, port: port) }

        let cert = try await WebDAVCertificateInspector.inspect(
            urlString: "https://127.0.0.1:8767/"
        )
        XCTAssertFalse(cert.systemTrusted)
        XCTAssertEqual(cert.fingerprint.count, 64)

        var settings = SMBSettings()
        settings.webDAVUsername = "filemann"
        settings.webDAVRemoteHost = host
        settings.webDAVRemotePort = String(port)
        settings.webDAVRemoteHTTPS = true

        do {
            _ = try await WebDAVArchiveService.resolveBestBaseURL(
                settings: settings, password: "filemann-pass"
            )
            XCTFail("Unpinned self-signed WAN certificate must be rejected")
        } catch {
            // Certificate trust must fail before any authenticated response.
        }

        let wrong = String(repeating: "A", count: 64)
        try WebDAVCertificateTrust.save(wrong, host: host, port: port)
        do {
            _ = try await WebDAVArchiveService.resolveBestBaseURL(
                settings: settings, password: "filemann-pass"
            )
            XCTFail("Mismatched pin must never permit access")
        } catch {
            // Wrong SHA-256 is rejected.
        }

        try WebDAVCertificateTrust.save(
            cert.fingerprint, host: host, port: port
        )
        let resolved = try await WebDAVArchiveService.resolveBestBaseURL(
            settings: settings, password: "filemann-pass"
        )
        XCTAssertEqual(resolved, "https://127.0.0.1:8767")
    }
    func testOptionalRemoteNASCompatibilityConnectsWithoutPin()
        async throws {
        let host = "127.0.0.1"
        let port = 8767
        WebDAVCertificateTrust.remove(host: host, port: port)

        var settings = SMBSettings()
        settings.webDAVUsername = "filemann"
        settings.webDAVRemoteHost = host
        settings.webDAVRemotePort = String(port)
        settings.webDAVRemoteHTTPS = true

        do {
            _ = try await WebDAVArchiveService.resolveBestBaseURL(
                settings: settings, password: "filemann-pass"
            )
            XCTFail("Default must reject untrusted TLS")
        } catch {
            // Safe default: no explicit opt-in.
        }

        settings.enableRemoteCertificateCompatibility()
        let restored = try JSONDecoder().decode(
            SMBSettings.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(restored.isRemoteCertificateCompatibilityEnabled)
        XCTAssertEqual(
            try await WebDAVArchiveService.resolveBestBaseURL(
                settings: restored, password: "filemann-pass"
            ),
            "https://127.0.0.1:8767"
        )

        var changed = restored
        changed.webDAVRemotePort = "8766"
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
        changed.disableRemoteCertificateCompatibility()
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
    }

}
