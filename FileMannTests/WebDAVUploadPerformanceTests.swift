import Foundation
import XCTest
@testable import FileMann

final class WebDAVUploadPerformanceTests: XCTestCase {
    func testSmallHEICsArePreparedForBackgroundDaemonBeforeAppSuspends() {
        let size: Int64 = 4 * 1024 * 1024
        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: size, inFlightSizes: []
            )
        )
        let staged = (0..<63).map { size + Int64($0) }
        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: size + 64,
                inFlightSizes: staged
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: size + 65,
                inFlightSizes: staged + [size + 64]
            )
        )
        XCTAssertEqual(
            WebDAVUploadSchedulingPolicy.maximumPreparedSmallUploads, 64
        )
        XCTAssertEqual(
            WebDAVUploadSchedulingPolicy.maximumHTTPConnections, 2
        )

        // Equal-sized media could be identical duplicates. Wait until
        // the first upload is verified before staging the second.
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: size,
                inFlightSizes: [size]
            )
        )
    }

    func testBackgroundPrestageBytesRemainBounded() {
        let largeHEIC: Int64 = 15 * 1024 * 1024
        let staged = (0..<25).map { largeHEIC + Int64($0) }
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: largeHEIC + 26,
                inFlightSizes: staged
            )
        )
        XCTAssertEqual(
            WebDAVUploadSchedulingPolicy.maximumPreparedBytes,
            384 * 1024 * 1024
        )
    }

    func testLargeVideosNeverOverlapOrStageAlongsideSmallMedia() {
        let large =
            WebDAVUploadSchedulingPolicy.largeFileThresholdBytes + 1
        let heic: Int64 = 3 * 1024 * 1024
        let separateLarge: Int64 = 20 * 1024 * 1024

        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: large, inFlightSizes: []
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: heic, inFlightSizes: [large]
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: large, inFlightSizes: [heic]
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: separateLarge, inFlightSizes: [heic]
            )
        )
    }

    func testZeroLengthMediaNeverOccupiesUploadSlot() {
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: 0, inFlightSizes: []
            )
        )
    }

    func testBackgroundModesAndTaskIdentifiersAreInAppBundle() {
        let bundle = Bundle.main
        let modes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes")
            as? [String] ?? []
        let identifiers = bundle.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String] ?? []
        XCTAssertTrue(modes.contains("fetch"))
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertTrue(identifiers.contains(
            ArchiveBackgroundTaskScheduler.refreshIdentifier
        ))
        XCTAssertTrue(identifiers.contains(
            ArchiveBackgroundTaskScheduler.processingIdentifier
        ))
        XCTAssertFalse(modes.contains("audio"),
                       "Silent audio cannot be used as an upload keep-alive")
    }

    func testProbedPrivateLANUsesFourConnectionsWhileWANUsesTwo() {
        var settings = SMBSettings()
        settings.webDAVLocalHost = "192.168.233.233"
        settings.webDAVLocalPort = "8900"
        settings.webDAVLocalHTTPS = false
        settings.webDAVRemoteHost = "nas.example.com"
        settings.webDAVRemoteHTTPS = true

        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.usesLocalLAN(
                endpoint: settings.normalizedWebDAVBaseURL, settings: settings
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.usesLocalLAN(
                endpoint: settings.normalizedWebDAVRemoteBaseURL,
                settings: settings
            )
        )
        XCTAssertEqual(
            WebDAVUploadSchedulingPolicy.maximumLANHTTPConnections, 4
        )
        XCTAssertEqual(
            WebDAVUploadSchedulingPolicy.maximumWANHTTPConnections, 2
        )
    }

    func testLANMediumFilesCanOverlapWithinStagingBudget() {
        let first: Int64 = 24 * 1024 * 1024
        let second = first + 1
        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: second, inFlightSizes: [first], isLocalLAN: true
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: second, inFlightSizes: [first], isLocalLAN: false
            )
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: second + 1,
                inFlightSizes: [first, second],
                isLocalLAN: true
            )
        )
    }

    func testSameSizedLANFilesNeedDifferentContentFingerprints() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("a.heic")
        let two = root.appendingPathComponent("b.heic")
        try Data("ABC".utf8).write(to: one)
        try Data("XYZ".utf8).write(to: two)
        let digestOne = try ArchiveSourceFingerprint.sha256(
            of: one, expectedBytes: 3
        )
        let digestTwo = try ArchiveSourceFingerprint.sha256(
            of: two, expectedBytes: 3
        )
        XCTAssertNotEqual(digestOne, digestTwo)
        XCTAssertEqual(
            digestOne,
            try ArchiveSourceFingerprint.sha256(of: one, expectedBytes: 3)
        )
        XCTAssertThrowsError(
            try ArchiveSourceFingerprint.sha256(of: one, expectedBytes: 4)
        )
        XCTAssertFalse(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: 3, inFlightSizes: [3], isLocalLAN: true
            )
        )
        XCTAssertTrue(
            WebDAVUploadSchedulingPolicy.canSchedule(
                fileSize: 3, inFlightSizes: [3], isLocalLAN: true,
                verifiedDifferentContentAtSameSize: true
            )
        )
    }

    func testBatchManifestChecksLiveListingAndIgnoresPhantomHead() async throws {
        let service = try mockWebDAVService(directory: "Album")
        let existing = try await service.downloadData(
            path: "Album/sample.jpg"
        )
        let nested = try await service.downloadData(
            path: "Album/Nested/nested.txt"
        )
        let result = await service.verifyPublishedBatch([
            (
                path: "Album/sample.jpg",
                expectedBytes: Int64(existing.count)
            ),
            (
                path: "Album/Nested/nested.txt",
                expectedBytes: Int64(nested.count)
            ),
            (
                path: "Album/phantom.mp4",
                expectedBytes: Int64(
                    "fake-file-size-only".utf8.count
                )
            )
        ])
        XCTAssertEqual(
            result["Album/sample.jpg"],
            Int64(existing.count)
        )
        XCTAssertEqual(
            result["Album/Nested/nested.txt"],
            Int64(nested.count)
        )
        XCTAssertNil(result["Album/phantom.mp4"])
    }

    func testBatchManifestDoesNotAcceptWrongSizeOrMissingFile() async throws {
        let service = try mockWebDAVService(directory: "Album")
        let result = await service.verifyPublishedBatch([
            (path: "Album/sample.jpg", expectedBytes: 1),
            (path: "Album/not-there.heic", expectedBytes: 100)
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testBatchManifestVerifiesMultipleNewFilesInSameParent() async throws {
        let service = try mockWebDAVService(directory: "PutOnly")
        let basename = UUID().uuidString.lowercased()
        let p1 = "PutOnly/\(basename)-1.heic"
        let p2 = "PutOnly/\(basename)-2.heic"
        let body1 = Data("HEIC source 1".utf8)
        let body2 = Data("HEIC source 2".utf8)

        for (path, data) in [(p1, body1), (p2, body2)] {
            var request = try service.makeUploadRequest(
                path: path, failIfExists: true
            )
            request.httpBody = data
            let (_, response) = try await URLSession.shared.data(
                for: request
            )
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.statusCode,
                201
            )
        }

        let result = await service.verifyPublishedBatch([
            (path: p1, expectedBytes: Int64(body1.count)),
            (path: p2, expectedBytes: Int64(body2.count))
        ])
        XCTAssertEqual(result[p1], Int64(body1.count))
        XCTAssertEqual(result[p2], Int64(body2.count))

        try await service.deleteRemoteFile(at: p1)
        try await service.deleteRemoteFile(at: p2)
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
}
