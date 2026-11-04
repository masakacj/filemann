import SwiftUI
import UIKit

final class FileMannAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        ArchiveBackgroundTaskScheduler.registerHandlers()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        WebDAVBackgroundUploadManager.shared.setBackgroundCompletionHandler(
            identifier: identifier,
            completionHandler: {
                // A background URLSession callback might be the only
                // reason iOS has relaunched us without a visible scene.
                Task { @MainActor in
                    _ = await ArchiveBackgroundTaskScheduler.runOnce(
                        reason: .session
                    )
                    completionHandler()
                }
            }
        )
    }
}

@main
struct FileMannApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(FileMannAppDelegate.self)
    private var appDelegate

    @StateObject private var viewModel: ArchiveViewModel

    init() {
        UITestBootstrap.applyIfNeeded()
        _viewModel = StateObject(
            wrappedValue: ArchiveViewModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .onAppear {
                    _ = try? FileMannShared.inboxDirectory()
                    viewModel.importShareInbox()
                    viewModel.resumeOnForegroundIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        viewModel.importShareInbox()
                        viewModel.resumeOnForegroundIfNeeded()
                    } else if phase == .background {
                        ArchiveBackgroundTaskScheduler.scheduleIfNeeded()
                    }
                }
                .task {
                    await FileMannCacheManager.shared
                        .prepareAtLaunch()
                    viewModel.syncConfigCenter(silent: true)
                }
        }
    }
}
