import BackgroundTasks
import Foundation
import UIKit

/// A BG task is an *opportunity* to refill transfers, not a keep-alive.
/// URLSession still owns the actual uploads while FileMann is suspended.
/// Register handlers with SwiftUI Scene.backgroundTask in FileMannApp.
@MainActor
enum ArchiveBackgroundTaskScheduler {
    static let refreshIdentifier =
        "com.masakacj.filemann.archive.refresh"
    static let processingIdentifier =
        "com.masakacj.filemann.archive.processing"

    private static weak var liveModel: ArchiveViewModel?

    static func attach(_ model: ArchiveViewModel) {
        liveModel = model
    }

    static var backgroundRefreshExplanation: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return "系统后台刷新已允许；具体唤醒时机会由 iOS 决定"
        case .denied:
            return "系统后台刷新已关闭；请到 iPhone 设置中允许后台 App 刷新"
        case .restricted:
            return "系统限制了后台刷新（可能由低电量或设备管理策略限制）"
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
    static func runOnce() async -> Bool {
        guard TaskStore.shouldResumeArchive() else { return true }
        let model = liveModel ?? ArchiveViewModel()
        let result = await model.refillAfterSystemWake()
        if TaskStore.shouldResumeArchive() {
            scheduleIfNeeded()
        } else {
            scheduleIfNeeded() // Cancels any obsolete scheduled requests.
        }
        return result
    }
}
