import BackgroundTasks
import Foundation
import UIKit

/// A BG task is an *opportunity* to refill transfers, not a keep-alive.
/// URLSession still owns the actual uploads while FileMann is suspended.
/// Register both BGTaskScheduler handlers before app launch completes.
@MainActor
enum ArchiveBackgroundTaskScheduler {
    static let refreshIdentifier =
        "com.masakacj.filemann.archive.refresh"
    static let processingIdentifier =
        "com.masakacj.filemann.archive.processing"

    enum WakeReason: String {
        case session = "URLSession"
        case refresh = "后台 App 刷新"
        case processing = "后台处理"
    }

    private static let lastWakeAtKey = "filemann.background.last.wake.v1"
    private static let lastWakeReasonKey = "filemann.background.last.reason.v1"
    private static weak var liveModel: ArchiveViewModel?

    static var lastSystemWakeDescription: String {
        guard let at = UserDefaults.standard.object(
            forKey: lastWakeAtKey
        ) as? Date else {
            return "还没有系统后台唤醒记录；需在真机锁屏后检查"
        }
        let source = UserDefaults.standard.string(
            forKey: lastWakeReasonKey
        ) ?? "系统"
        return "最近后台唤醒：\(at.formatted(date: .abbreviated, time: .shortened))（\(source)）"
    }

    /// Explicit registration works on iOS 17/18 as well as newer releases.
    /// The SwiftUI .processing BackgroundTask convenience isn't provided by
    /// the version of SwiftUI bundled with our pinned Xcode 16.4 toolchain.
    static func registerHandlers() {
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                self.handle(task, reason: .refresh)
            }
        }
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                self.handle(task, reason: .processing)
            }
        }
        if !refreshRegistered || !processingRegistered {
            NSLog("FileMann BGTaskScheduler handler registration failed")
        }
    }

    private static func handle(_ task: BGTask, reason: WakeReason) {
        let worker = Task { @MainActor in
            await runOnce(reason: reason)
        }
        task.expirationHandler = {
            worker.cancel()
        }
        Task { @MainActor in
            let succeeded = await worker.value
            task.setTaskCompleted(success: succeeded)
        }
    }

    static func attach(_ model: ArchiveViewModel) {
        liveModel = model
    }

    static var backgroundRefreshExplanation: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "系统后台刷新已允许；具体唤醒时机会由 iOS 决定"
        case .denied:
            return "后台 App 刷新不可用；检查系统开关或是否开启低电量模式"
        case .restricted:
            return "设备管理或家长控制限制了后台刷新，可能无法手动开启"
        @unknown default:
            return "暂时无法确定后台刷新状态"
        }
    }

    static func scheduleIfNeeded() {
        guard TaskStore.shouldResumeArchive() else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: refreshIdentifier
            )
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: processingIdentifier
            )
            return
        }

        // Replacing an older pending request is deliberate: there must be
        // at most one request of either kind, not a new request per file.
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: refreshIdentifier
        )
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: processingIdentifier
        )

        let refresh = BGAppRefreshTaskRequest(
            identifier: refreshIdentifier
        )
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        let processing = BGProcessingTaskRequest(
            identifier: processingIdentifier
        )
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)

        do {
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            NSLog("FileMann app refresh scheduling: %@", error.localizedDescription)
        }
        do {
            try BGTaskScheduler.shared.submit(processing)
        } catch {
            NSLog("FileMann BGProcessing scheduling: %@", error.localizedDescription)
        }
    }

    /// Used both by the system's scheduled task and by the completion of
    /// a restored background URLSession (which may wake the app without UI).
    /// Do not claim success or tell UIKit we're done until a refill attempt
    /// has finished handing more file tasks to the background daemon.
    @discardableResult
    static func runOnce(
        reason: WakeReason
    ) async -> Bool {
        UserDefaults.standard.set(Date(), forKey: lastWakeAtKey)
        UserDefaults.standard.set(
            reason.rawValue, forKey: lastWakeReasonKey
        )
        guard TaskStore.shouldResumeArchive() else { return true }
        let model = liveModel ?? ArchiveViewModel()
        let result = await model.refillAfterSystemWake()
        scheduleIfNeeded() // Re-arm if needed, or cancel after batch finish.
        return result
    }
}
