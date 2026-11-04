import Foundation
import XCTest
@testable import FileMann

final class FileMannTemporaryStorageTests: XCTestCase {
    func testDiagnosticsSeparateOldAndRecentTemporaryFiles() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = root.appendingPathComponent("archived.heic")
        let newFile = root.appendingPathComponent("fresh.mov")
        try Data(repeating: 4, count: 2048).write(to: oldFile)
        try Data(repeating: 5, count: 1024).write(to: newFile)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1200)],
            ofItemAtPath: oldFile.path
        )
        let snapshot = FileMannTemporaryStorage.inspect(
            under: root, at: now
        )
        XCTAssertEqual(snapshot.fileCount, 2)
        XCTAssertEqual(snapshot.reclaimableCount, 1)
        XCTAssertGreaterThan(snapshot.reclaimableBytes, 0)
        XCTAssertEqual(snapshot.largestFiles.count, 2)
        XCTAssertTrue(snapshot.largestFiles.contains {
            $0.path == "archived.heic"
        })
    }

    func testCleanupLeavesRecentFilesAndNeverFollowsSymlinks() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = root.appendingPathComponent("old-upload.partial")
        let recent = root.appendingPathComponent("current-upload.mov")
        try Data(repeating: 1, count: 2048).write(to: stale)
        try Data(repeating: 2, count: 1024).write(to: recent)
        let link = root.appendingPathComponent("some-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: recent
        )
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)],
            ofItemAtPath: stale.path
        )

        let result = FileMannTemporaryStorage.removeStaleFiles(
            under: root, at: now
        )
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertGreaterThan(result.removedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testEmptyRootDoesNotReportOrDeleteAnything() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = FileMannTemporaryStorage.inspect(under: root)
        XCTAssertEqual(snapshot.fileCount, 0)
        XCTAssertEqual(snapshot.totalBytes, 0)
        XCTAssertEqual(snapshot.reclaimableCount, 0)
        let cleaned = FileMannTemporaryStorage.removeStaleFiles(
            under: root
        )
        XCTAssertEqual(cleaned.removedCount, 0)
        XCTAssertEqual(cleaned.removedBytes, 0)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "filemann-cleanup-test-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }
}
