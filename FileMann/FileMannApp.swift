import SwiftUI
import UIKit

final class FileMannAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        WebDAVBackgroundUploadManager.shared.setBackgroundCompletionHandler(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct FileMannApp: App {
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
                }
        }
    }
}
