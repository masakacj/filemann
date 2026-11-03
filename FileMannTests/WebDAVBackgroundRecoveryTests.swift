import Foundation
import XCTest
@testable import FileMann

final class WebDAVBackgroundRecoveryTests: XCTestCase {
    func testVerifiedReceiptSurvivesColdStartAndIsRemovedAfterUse() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let taskID = UUID()
        let verified = WebDAVBackgroundReceipt.verified(
            taskID: taskID,
            endpoint: "https://nas.example.com:443/storage",
            path: "Documentsf/Apps/IMG_1024.HEIC",
            size: 2_843_542
        )
        try WebDAVBackgroundReceiptStore.save(verified, under: root)

        let reloaded = WebDAVBackgroundReceiptStore.load(under: root)
        XCTAssertEqual(reloaded, [verified])
        XCTAssertEqual(reloaded[0].outcome, .verified)
        XCTAssertEqual(
            reloaded[0].remotePath, "Documentsf/Apps/IMG_1024.HEIC"
        )

        WebDAVBackgroundReceiptStore.remove(
            taskID: taskID, under: root
        )
        XCTAssertTrue(
            WebDAVBackgroundReceiptStore.load(under: root).isEmpty
        )
    }

    func testFailedUploadReceiptNeverPretendsNASFileVerified() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = WebDAVBackgroundReceipt.failed(
            taskID: UUID(), message: "网络已断开"
        )
        try WebDAVBackgroundReceiptStore.save(receipt, under: root)
        let loaded = try XCTUnwrap(
            WebDAVBackgroundReceiptStore.load(under: root).first
        )
        XCTAssertEqual(loaded.outcome, .failed)
        XCTAssertNil(loaded.remotePath)
        XCTAssertNil(loaded.remoteSize)
        XCTAssertNil(loaded.endpoint)
        XCTAssertEqual(loaded.message, "网络已断开")
    }

    func testTwoReceiptsDoNotOverwriteEachOther() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = WebDAVBackgroundReceipt.verified(
            taskID: UUID(),
            endpoint: "http://192.168.233.233:8900/storage",
            path: "Apps/a.HEIC",
            size: 234_567
        )
        let second = WebDAVBackgroundReceipt.verified(
            taskID: UUID(),
            endpoint: "https://example.org/storage",
            path: "Apps/b.HEIC",
            size: 345_678
        )
        try WebDAVBackgroundReceiptStore.save(first, under: root)
        try WebDAVBackgroundReceiptStore.save(second, under: root)
        let loaded = WebDAVBackgroundReceiptStore.load(under: root)
        XCTAssertEqual(Set(loaded.map(\.taskID)), [first.taskID, second.taskID])
    }

    func testVerifiedReceiptCannotBeReusedForAnotherEndpointOrName() {
        var task = ArchiveTask(
            bookmark: Data(),
            displayName: "IMG_2011.HEIC",
            remoteFileName: "IMG_2011.HEIC",
            fileSize: 2000,
            sourceModifiedAt: nil
        )
        task.remoteEndpointURL = "https://nas.example.com:443/storage"
        task.attemptedRemotePath = "Apps/IMG_2011.HEIC"

        let receipt = WebDAVBackgroundReceipt.verified(
            taskID: task.id,
            endpoint: task.remoteEndpointURL!,
            path: task.attemptedRemotePath!,
            size: task.fileSize
        )
        XCTAssertTrue(receipt.matchesVerifiedUpload(task))

        var changedEndpoint = task
        changedEndpoint.remoteEndpointURL =
            "http://192.168.233.233:8900/storage"
        XCTAssertFalse(receipt.matchesVerifiedUpload(changedEndpoint))

        var renamed = task
        renamed.attemptedRemotePath = "Apps/IMG_2011 (2).HEIC"
        XCTAssertFalse(receipt.matchesVerifiedUpload(renamed))

        var changedBytes = task
        changedBytes.fileSize += 1
        XCTAssertFalse(receipt.matchesVerifiedUpload(changedBytes))

        let unrelated = WebDAVBackgroundReceipt.verified(
            taskID: UUID(),
            endpoint: task.remoteEndpointURL!,
            path: task.attemptedRemotePath!,
            size: task.fileSize
        )
        XCTAssertFalse(unrelated.matchesVerifiedUpload(task))
    }

    func testResumeIntentExplicitlyControlsAutomaticRecovery() {
        let oldValue = TaskStore.shouldResumeArchive()
        defer { TaskStore.setShouldResumeArchive(oldValue) }
        TaskStore.setShouldResumeArchive(true)
        XCTAssertTrue(TaskStore.shouldResumeArchive())
        TaskStore.setShouldResumeArchive(false)
        XCTAssertFalse(TaskStore.shouldResumeArchive())
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        return root
    }
}
