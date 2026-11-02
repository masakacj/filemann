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

    func testRemoteCertificateCompatibilityRequiresExplicitEndpointGrant() throws {
        var settings = SMBSettings()
        settings.webDAVRemoteHost = "nas.example.com"
        settings.webDAVRemotePort = "18443"
        settings.webDAVRemotePath = "/webdav"
        settings.webDAVRemoteHTTPS = true

        // A legacy Bool alone must never enable a WAN TLS bypass.
        settings.webDAVRemoteAllowInvalidCertificate = true
        XCTAssertFalse(settings.isRemoteCertificateCompatibilityEnabled)

        settings.enableRemoteCertificateCompatibility()
        XCTAssertTrue(settings.isRemoteCertificateCompatibilityEnabled)
        XCTAssertTrue(settings.webDAVAllowsInvalidCertificate(
            for: "https://nas.example.com:18443/webdav"
        ))
        XCTAssertTrue(settings.webDAVAllowsInvalidCertificate(
            host: "nas.example.com", port: 18443
        ))
        XCTAssertFalse(settings.webDAVAllowsInvalidCertificate(
            host: "nas.example.com", port: 443
        ))
        XCTAssertFalse(settings.webDAVAllowsInvalidCertificate(
            for: "https://other.example.com:18443/webdav"
        ))

        let saved = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(SMBSettings.self, from: saved)
        XCTAssertTrue(restored.isRemoteCertificateCompatibilityEnabled)
        XCTAssertTrue(restored.webDAVAllowsInvalidCertificate(
            for: restored.normalizedWebDAVRemoteBaseURL
        ))

        var changed = restored
        changed.webDAVRemoteHost = "other.example.com"
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
        changed = restored
        changed.webDAVRemotePort = "18444"
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
        changed = restored
        changed.webDAVRemotePath = "/different"
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
        changed = restored
        changed.disableRemoteCertificateCompatibility()
        XCTAssertFalse(changed.isRemoteCertificateCompatibilityEnabled)
    }

    func testConfigCenterCannotTurnOnRemoteCompatibility() throws {
        var existing = SMBSettings()
        existing.webDAVRemoteHost = "nas.example.com"
        existing.webDAVRemoteHTTPS = true
        let payload = Data("""
        {"webdav":{"allowInvalidRemoteCertificate":true,
                   "remoteURL":"https://nas.example.com/"}}
        """.utf8)
        let config = try JSONDecoder().decode(
            FileMannRemoteConfig.self, from: payload
        )
        let updated = try config.applying(to: existing)
        XCTAssertFalse(updated.isRemoteCertificateCompatibilityEnabled)

        var optedIn = updated
        optedIn.enableRemoteCertificateCompatibility()
        XCTAssertTrue(optedIn.isRemoteCertificateCompatibilityEnabled)
        let same = try config.applying(to: optedIn)
        XCTAssertTrue(same.isRemoteCertificateCompatibilityEnabled)

        let newURL = try JSONDecoder().decode(
            FileMannRemoteConfig.self,
            from: Data("""
            {"webdav":{"remoteURL":"https://new-nas.example.com/"}}
            """.utf8)
        )
        XCTAssertFalse(try newURL.applying(to: optedIn)
            .isRemoteCertificateCompatibilityEnabled)
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

    func testSelectExistingWebDAVFolderWithoutSMBPath() async throws {
        // The stale server-side SMB path must not be assumed to exist on DAV.
        let service = try mockWebDAVService(
            directory: "storage/Documentsf/Apps"
        )
        do {
            try await service.testConnection()
            XCTFail("An SMB-only path must not trigger automatic MKCOL")
        } catch WebDAVArchiveError.archiveDirectoryMissing(let path) {
            XCTAssertEqual(path, "storage/Documentsf/Apps")
        }

        // The user may instead choose a browsable, writable DAV folder.
        try await service.verifyWritableDirectory(at: "Album")
    }

    func testSelectReadOnlyDAVDirectoryReturnsActionable403() async throws {
        let service = try mockWebDAVService(directory: "ReadOnly")
        do {
            try await service.verifyWritableDirectory(at: "ReadOnly")
            XCTFail("A read-only NAS folder must never be selected")
        } catch WebDAVArchiveError.forbidden(let operation, let path) {
            XCTAssertTrue(operation.contains("PUT"))
            XCTAssertTrue(path.contains("/ReadOnly/"))
        }
    }

    func testRejectNonWebDAVHTTP200HTMLProxyResponse() async throws {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "127.0.0.1"
        settings.webDAVLocalPort = "8765"
        settings.webDAVLocalPath = "/NotWebDAV"
        settings.webDAVLocalHTTPS = false
        settings.webDAVUsername = "filemann"
        do {
            _ = try await WebDAVArchiveService.resolveBestBaseURL(
                settings: settings, password: "filemann-pass"
            )
            XCTFail("HTML 200 must not be mistaken for a DAV PROPFIND")
        } catch {
            // A real WebDAV multistatus is required to select an endpoint.
        }
    }

    func testWriteCheckReportsForbiddenPUT() async throws {
        let service = try mockWebDAVService(directory: "ReadOnly")

        do {
            try await service.testConnection()
            XCTFail("A read-only directory must fail the write check")
        } catch WebDAVArchiveError.forbidden(let operation, let path) {
            XCTAssertTrue(operation.contains("PUT"))
            XCTAssertTrue(path.contains("/ReadOnly/"))
        }
    }

    func testPublishedFileRequiresActualParentDirectoryListing() async throws {
        let service = try mockWebDAVService(directory: "Album")
        let valid = try await service.verifyPublishedFile(
            at: "Album/sample.jpg",
            expectedBytes: Int64(
                try await service.downloadData(path: "Album/sample.jpg").count
            )
        )
        XCTAssertEqual(valid.remotePath, "Album/sample.jpg")

        // Fake HEAD says 200 and advertises a plausible size. The file
        // never appears in Depth:1 PROPFIND, so do not mark it completed.
        let phantomSize = await service.remoteFileSize(
            atPath: "Album/phantom.mp4"
        )
        XCTAssertEqual(phantomSize, Int64("fake-file-size-only".utf8.count))
        do {
            _ = try await service.verifyPublishedFile(
                at: "Album/phantom.mp4",
                expectedBytes: Int64("fake-file-size-only".utf8.count)
            )
            XCTFail("HEAD-only files must not count as uploaded")
        } catch WebDAVArchiveError.remoteFileNotListed(let url) {
            XCTAssertTrue(url.contains("Album/phantom.mp4"))
        }

        do {
            _ = try await service.verifyPublishedFile(
                at: "Album/sample.jpg",
                expectedBytes: 1
            )
            XCTFail("A wrong directory listing size must be rejected")
        } catch WebDAVArchiveError.remoteFileSizeMismatch {
            // Expected: the exact path exists, but the size differs.
        }
    }

    func testPutOnlyNASUsesSafeDirectPUT() async throws {
        let service = try mockWebDAVService(directory: "PutOnly")
        let mode = try await service.preferredUploadMode()
        XCTAssertEqual(mode, .directPut)

        let path = "PutOnly/ios-" + UUID().uuidString + ".txt"
        let body = Data("FileMann direct upload".utf8)
        var request = try service.makeUploadRequest(
            path: path,
            failIfExists: true
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-None-Match"),
            "*"
        )
        request.httpBody = body
        let (_, created) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((created as? HTTPURLResponse)?.statusCode, 201)

        let result = try await service.finalizeBackgroundUpload(
            partialPath: path,
            finalPath: path,
            expectedBytes: Int64(body.count),
            uploadMode: .directPut
        )
        XCTAssertEqual(result.remotePath, path)
        XCTAssertEqual(result.remoteSize, Int64(body.count))

        // A retry must never silently overwrite an existing NAS file.
        var retry = try service.makeUploadRequest(
            path: path,
            failIfExists: true
        )
        retry.httpBody = Data("overwrite?".utf8)
        let (_, refused) = try await URLSession.shared.data(for: retry)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 412)
        let savedSize = await service.remoteFileSize(atPath: path)
        XCTAssertEqual(savedSize, Int64(body.count))
        try await service.deleteRemoteFile(at: path)
    }

    func testRecursiveDuplicateScanWorksWithoutDepthInfinity() async throws {
        let service = try mockWebDAVService(directory: "Album")
        let data = try await service.downloadData(
            path: "Album/Nested/nested.txt"
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let task = ArchiveTask(
            bookmark: Data(),
            displayName: "nested.txt",
            remoteFileName: "nested.txt",
            fileSize: Int64(data.count),
            sourceModifiedAt: nil
        )
        let duplicate = try await service.findExactDuplicate(
            task: task,
            sourceURL: source
        )
        XCTAssertEqual(duplicate?.path, "Album/Nested/nested.txt")
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
