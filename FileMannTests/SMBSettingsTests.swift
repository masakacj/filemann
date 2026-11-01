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

    func testSMBURLWithNASShareAndFolder() {
        var settings = SMBSettings()
        settings.host = "smb://192.168.233.233/storage/Documentsf/Apps"
        XCTAssertEqual(settings.normalizedHost, "192.168.233.233")
        XCTAssertEqual(settings.normalizedShare, "storage")
        XCTAssertEqual(settings.normalizedDirectory, "Documentsf/Apps")
        XCTAssertEqual(
            settings.smbConnectionSummary,
            "smb://192.168.233.233/storage/Documentsf/Apps"
        )
    }

    func testWindowsUNCPathConvertsToShare() {
        var settings = SMBSettings()
        settings.host = #"\\192.168.233.233\storage\Documentsf\Apps"#
        XCTAssertEqual(settings.normalizedHost, "192.168.233.233")
        XCTAssertEqual(settings.normalizedShare, "storage")
        XCTAssertEqual(settings.normalizedDirectory, "Documentsf/Apps")
    }

    func testShareFieldContainingFolderDoesNotBecomeShareName() {
        var settings = SMBSettings()
        settings.host = "192.168.233.233"
        settings.share = "storage/Documentsf/Apps"
        XCTAssertEqual(settings.normalizedShare, "storage")
        XCTAssertEqual(settings.normalizedDirectory, "Documentsf/Apps")
    }

    func testPlainSMBHostShareAndExplicitDirectory() {
        var settings = SMBSettings()
        settings.host = "192.168.233.233"
        settings.share = "storage"
        settings.remoteDirectory = "Documentsf/Apps"
        XCTAssertEqual(settings.normalizedHost, "192.168.233.233")
        XCTAssertEqual(settings.normalizedShare, "storage")
        XCTAssertEqual(settings.normalizedDirectory, "Documentsf/Apps")
    }

    func testWebDAVRejectsDuplicatedRootBeforeNetworkWrite() async throws {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalHTTPS = false
        settings.webDAVLocalPath = "/storage"
        settings.webDAVRemoteDirectory = "storage/Documentsf/Apps"

        let service = try WebDAVArchiveService(
            settings: settings,
            password: "none"
        )
        do {
            try await service.connectAndPrepare()
            XCTFail("Duplicated archive path must be rejected")
        } catch WebDAVArchiveError.duplicateArchiveDirectory(let base, let directory) {
            XCTAssertEqual(base, "/storage")
            XCTAssertEqual(directory, "storage/Documentsf/Apps")
        }
    }

    func testWebDAVShareRootURLCanBeArchiveDestination() async throws {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalHTTPS = false
        settings.webDAVLocalPath = "/Album"
        XCTAssertTrue(settings.hasWebDAVArchiveDirectory)

        let service = try WebDAVArchiveService(
            settings: settings,
            password: "filemann-pass"
        )
        // The mock supports PUT/MOVE/DELETE in /Album, even when the
        // relative archive subfolder is empty.
        try await service.testConnection()
    }

    func testBareNASRootIsNotWritableArchiveDestination() async throws {
        let service = try mockWebDAVService(directory: "")
        do {
            try await service.testConnection()
            XCTFail("NAS site root cannot be used as archive folder")
        } catch WebDAVArchiveError.missingArchiveDestination {
            // Confirm an explicit unsafe-root error, not an implicit 403.
        }
    }

    func testWriteCheckSucceedsForWritableDirectory() async throws {
        let service = try mockWebDAVService(directory: "Album")
        try await service.testConnection()
    }

    func testWritableLeafDoesNotRequireParentBrowsePermission() async throws {
        // ParentDenied is intentionally 403, but the final Upload folder
        // supports read, write, rename and delete, like a restricted NAS.
        let service = try mockWebDAVService(
            directory: "ParentDenied/Upload"
        )
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
