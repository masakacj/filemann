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
        XCTAssertFalse(
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

    func testLegacySMBSettingDecodesAsWebDAVOnly() throws {
        let saved = Data("""
        {"transport":"smb","host":"192.168.233.233",
         "webDAVLocalHost":"192.168.233.233",
         "webDAVLocalPort":"8900","webDAVLocalHTTPS":false}
        """.utf8)
        let settings = try JSONDecoder().decode(SMBSettings.self, from: saved)
        XCTAssertEqual(settings.transport, .webDAV)
        XCTAssertTrue(settings.isValid)
    }

    func testPublicHTTPIsNeverUsedForWebDAV() {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "nas.example.org"
        settings.webDAVLocalHTTPS = false
        settings.webDAVRemoteHost = "remote.example.org"
        settings.webDAVRemoteHTTPS = false
        XCTAssertTrue(settings.webDAVCandidateBaseURLs.isEmpty)

        settings.webDAVRemoteHTTPS = true
        XCTAssertEqual(
            settings.webDAVCandidateBaseURLs,
            ["https://remote.example.org"]
        )
        XCTAssertTrue(SMBSettings.isPrivateLANHTTPURL(
            "http://192.168.233.233:8900"
        ))
        XCTAssertFalse(SMBSettings.isPrivateLANHTTPURL(
            "http://public.example.org:8900"
        ))
    }

    func testWANNeverPermitsInvalidCertificates() {
        var settings = SMBSettings()
        settings.webDAVRemoteHost = "remote.example.org"
        settings.webDAVRemoteHTTPS = true
        settings.webDAVRemoteAllowInvalidCertificate = true
        XCTAssertFalse(settings.webDAVAllowsInvalidCertificate(
            for: settings.normalizedWebDAVRemoteBaseURL
        ))
    }

    func testServerSMBTransportCannotReenableLegacyProtocol() throws {
        let data = Data("""
        {"transfer":{"transport":"smb"},
         "webdav":{"localURL":"http://192.168.233.233:8900/"}}
        """.utf8)
        let config = try JSONDecoder().decode(
            FileMannRemoteConfig.self, from: data
        )
        let result = try config.applying(to: SMBSettings())
        XCTAssertEqual(result.transport, .webDAV)
    }

    func testWebDAVRejectsDuplicatedSharedDirectoryPrefix() async throws {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalHTTPS = false
        settings.webDAVLocalPath = "/storage"
        settings.webDAVRemoteDirectory = "storage/Documentsf/Apps"
        let service = try WebDAVArchiveService(
            settings: settings, password: "filemann-pass"
        )
        do {
            try await service.connectAndPrepare()
            XCTFail("The WebDAV share must not be repeated in the path")
        } catch WebDAVArchiveError.duplicateArchiveDirectory {
            // Identifies the wrong path before a write is attempted.
        }
    }

    func testWritableLeafWithoutParentBrowsePermission() async throws {
        let service = try mockWebDAVService(
            directory: "ParentDenied/Upload"
        )
        try await service.testConnection()
    }

    func testWebDAVShareRootWithValidAuthIsWritable() async throws {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalPath = "/Album"
        settings.webDAVLocalHTTPS = false
        settings.webDAVUsername = "filemann"
        let service = try WebDAVArchiveService(
            settings: settings, password: "filemann-pass"
        )
        XCTAssertTrue(settings.hasWebDAVArchiveDirectory)
        try await service.testConnection()
    }

    func testWebDAVBareNASRootIsNotArchiveDestination() async throws {
        let service = try mockWebDAVService(directory: "")
        do {
            try await service.testConnection()
            XCTFail("Unsafe NAS root must not accept uploads")
        } catch WebDAVArchiveError.missingArchiveDestination {
            // The NAS site root is read-only until a share is selected.
        }
    }

    func testWriteCheckSucceedsForWritableDirectory() async throws {
        let service = try mockWebDAVService(directory: "Album")
        try await service.testConnection()
    }

    func testWriteCheckReportsForbiddenPUT() async throws {
        let service = try mockWebDAVService(directory: "ReadOnly")

        do {
            try await service.testConnection()
            XCTFail("A read-only directory must fail the write check")
        } catch WebDAVArchiveError.forbidden(let operation, let path) {
            XCTAssertTrue(operation.contains("PUT"))
            XCTAssertTrue(path.hasPrefix("ReadOnly/"))
        }
    }

    private func mockWebDAVService(
        directory: String
    ) throws -> WebDAVArchiveService {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalHTTPS = false
        settings.webDAVUsername = "filemann"
        settings.webDAVRemoteDirectory = directory
        return try WebDAVArchiveService(
            settings: settings,
            password: "filemann-pass"
        )
    }

    func testRemoteConfigurationPreservesMissingValues() throws {
        let config = try JSONDecoder().decode(
            FileMannRemoteConfig.self,
            from: Data("""
            {"webdav":{"localURL":"http://192.168.233.233:8900"},
             "transfer":{"transport":"webDAV","deleteAfterArchive":false}}
            """.utf8)
        )
        var existing = SMBSettings()
        existing.webDAVUsername = "preserve-user"
        existing.webDAVRemoteDirectory = "Shared/MyFiles"
        let result = try config.applying(to: existing)
        XCTAssertEqual(
            result.normalizedWebDAVBaseURL,
            "http://192.168.233.233:8900"
        )
        XCTAssertEqual(result.webDAVUsername, "preserve-user")
        XCTAssertEqual(result.normalizedWebDAVDirectory, "Shared/MyFiles")
        XCTAssertFalse(result.deleteAfterArchive)
    }

    func testRejectInsecureRemoteConfigURL() throws {
        let config = try JSONDecoder().decode(
            FileMannRemoteConfig.self,
            from: Data(
                #"{"webdav":{"remoteURL":"http://nas.example.com/webdav"}}"#
                .utf8
            )
        )
        XCTAssertThrowsError(try config.applying(to: SMBSettings()))
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
