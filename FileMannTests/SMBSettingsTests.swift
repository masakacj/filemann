import XCTest
@testable import FileMann

final class SMBSettingsTests: XCTestCase {
    func testComposesCustomHTTPSAddress() {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "nas.example.com"
        settings.webDAVLocalPort = "18443"
        settings.webDAVLocalPath = "/dav/media/"
        settings.webDAVLocalHTTPS = true

        XCTAssertEqual(
            settings.normalizedWebDAVBaseURL,
            "https://nas.example.com:18443/dav/media"
        )
    }

    func testCandidateOrderPrefersLocal() {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "192.168.1.10"
        settings.webDAVLocalPort = "5000"
        settings.webDAVLocalHTTPS = false
        settings.webDAVRemoteHost = "nas.example.com"
        settings.webDAVRemotePort = "443"
        settings.webDAVRemoteHTTPS = true

        XCTAssertEqual(
            settings.webDAVCandidateBaseURLs,
            [
                "http://192.168.1.10:5000",
                "https://nas.example.com:443"
            ]
        )
    }

    func testCertificateCompatibilityIsEndpointScoped() {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "192.168.1.10"
        settings.webDAVLocalPort = "5001"
        settings.webDAVLocalHTTPS = true
        settings.webDAVLocalAllowInvalidCertificate = false

        settings.webDAVRemoteHost = "nas.example.com"
        settings.webDAVRemotePort = "18443"
        settings.webDAVRemoteHTTPS = true
        settings.webDAVRemoteAllowInvalidCertificate = true

        XCTAssertFalse(
            settings.webDAVAllowsInvalidCertificate(
                host: "192.168.1.10",
                port: 5001
            )
        )
        XCTAssertTrue(
            settings.webDAVAllowsInvalidCertificate(
                host: "nas.example.com",
                port: 18443
            )
        )
    }

    func testWebDAVArchiveDirectoryConfiguration() {
        var settings = SMBSettings()
        XCTAssertFalse(settings.hasWebDAVArchiveDirectory)

        settings.webDAVRemoteDirectory = " /Public/Archive/ "

        XCTAssertTrue(settings.hasWebDAVArchiveDirectory)
        XCTAssertEqual(
            settings.normalizedWebDAVDirectory,
            "Public/Archive"
        )
    }

    func testConnectionTitlesFollowResolvedURL() {
        var settings = SMBSettings()
        settings.webDAVLocalTitle = "Home"
        settings.webDAVLocalHost = "192.168.1.10"
        settings.webDAVLocalHTTPS = false
        settings.webDAVRemoteTitle = "Away"
        settings.webDAVRemoteHost = "nas.example.com"
        settings.webDAVRemoteHTTPS = true

        XCTAssertEqual(
            settings.webDAVTitle(
                for: settings.normalizedWebDAVBaseURL
            ),
            "Home"
        )
        XCTAssertEqual(
            settings.webDAVTitle(
                for: settings.normalizedWebDAVRemoteBaseURL
            ),
            "Away"
        )
    }
}
