import Foundation
import XCTest
@testable import FileMann

final class DuplicateBatchSelectionTests: XCTestCase {
    func testSingleUnresolvedDuplicateOffersBulkKeepNAS() {
        let task = makeTask()
        var candidates = [makeCandidate(task)]

        XCTAssertEqual(
            DuplicateBatchSelection.selectableKeepNASCount(
                candidates: candidates, tasks: [task]
            ), 1
        )

        let changed = DuplicateBatchSelection.selectKeepNAS(
            candidates: &candidates, tasks: [task]
        )
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(candidates[0].decision, .keepNAS)
        XCTAssertEqual(
            DuplicateBatchSelection.selectableKeepNASCount(
                candidates: candidates, tasks: [task]
            ), 0
        )
    }

    func testBulkKeepNASReplacesUnappliedDecisionsWithoutTouchingFinalizedItems() {
        let pending = makeTask()
        var previouslyKeepPhone = makeTask()
        previouslyKeepPhone.state = .paused
        var previouslyKeepBoth = makeTask()
        previouslyKeepBoth.state = .failed
        var done = makeTask()
        done.state = .completed
        var skipped = makeTask()
        skipped.state = .skipped

        var candidates = [
            makeCandidate(pending, decision: .unresolved),
            makeCandidate(previouslyKeepPhone, decision: .keepPhone),
            makeCandidate(previouslyKeepBoth, decision: .keepBoth),
            makeCandidate(done, decision: .keepBoth),
            makeCandidate(skipped, decision: .keepPhone),
        ]
        let tasks = [pending, previouslyKeepPhone, previouslyKeepBoth, done, skipped]
        XCTAssertEqual(
            DuplicateBatchSelection.selectableKeepNASCount(
                candidates: candidates, tasks: tasks
            ), 3
        )

        XCTAssertEqual(
            DuplicateBatchSelection.selectKeepNAS(
                candidates: &candidates, tasks: tasks
            ), 3
        )
        XCTAssertEqual(candidates.map(\.decision), [
            .keepNAS, .keepNAS, .keepNAS, .keepBoth, .keepPhone
        ])
        XCTAssertEqual(
            DuplicateBatchSelection.selectKeepNAS(
                candidates: &candidates, tasks: tasks
            ), 0
        )
    }

    func testExplicitKeepNASDeletesPhoneOnlyUnderVerifiedCleanupStage() {
        var task = makeTask()
        task.shouldDeleteSource = true
        XCTAssertTrue(
            task.shouldCleanupLocalCopy(defaultDeleteAfterArchive: false),
            "Explicit keep NAS must work even with global auto-delete off"
        )

        task.shouldDeleteSource = false
        XCTAssertFalse(
            task.shouldCleanupLocalCopy(defaultDeleteAfterArchive: true),
            "Explicit keep both must override global auto-delete"
        )

        task.shouldDeleteSource = nil
        XCTAssertFalse(
            task.shouldCleanupLocalCopy(defaultDeleteAfterArchive: false)
        )
        XCTAssertTrue(
            task.shouldCleanupLocalCopy(defaultDeleteAfterArchive: true)
        )

        task.isShareStaging = true
        XCTAssertTrue(
            task.shouldCleanupLocalCopy(defaultDeleteAfterArchive: false)
        )
    }

    private func makeTask() -> ArchiveTask {
        ArchiveTask(
            bookmark: Data(),
            displayName: "IMG_2026.HEIC",
            remoteFileName: "IMG_2026.HEIC",
            fileSize: 125_000,
            sourceModifiedAt: nil
        )
    }

    private func makeCandidate(
        _ task: ArchiveTask,
        decision: DuplicateDecision = .unresolved
    ) -> DuplicateCandidate {
        var candidate = DuplicateCandidate(
            taskID: task.id,
            remotePath: "Album/IMG_2026.HEIC",
            remoteName: "IMG_2026.HEIC",
            fileSize: task.fileSize
        )
        candidate.decision = decision
        return candidate
    }
}
