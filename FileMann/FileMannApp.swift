import SwiftUI

@main
struct FileMannApp: App {
    @StateObject private var viewModel = ArchiveViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    _ = try? FileMannShared.inboxDirectory()
                }
        }
    }
}
