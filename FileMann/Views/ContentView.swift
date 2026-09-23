import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MediaLibraryView()
                .tabItem {
                    Label("本地", systemImage: "photo.on.rectangle.angled")
                }

            RemoteMediaTabView()
                .tabItem {
                    Label("NAS", systemImage: "externaldrive.fill")
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct RemoteMediaTabView: View {
    @EnvironmentObject private var archiveViewModel: ArchiveViewModel

    private var identity: String {
        [
            archiveViewModel.settings.normalizedWebDAVBaseURL,
            archiveViewModel.settings.normalizedWebDAVRemoteBaseURL,
            archiveViewModel.settings.normalizedWebDAVDirectory,
            archiveViewModel.settings.webDAVUsername,
            archiveViewModel.webDAVPassword
        ].joined(separator: "|")
    }

    var body: some View {
        Group {
            if archiveViewModel.settings.transport == .webDAV,
               archiveViewModel.settings.isValid {
                RemoteMediaBrowserView(
                    settings: archiveViewModel.settings,
                    password: archiveViewModel.webDAVPassword,
                    showsDismissButton: false,
                    onSettings: {
                        archiveViewModel.isShowingSettings = true
                    }
                )
                .id(identity)
            } else {
                NavigationStack {
                    ContentUnavailableView {
                        Label(
                            "尚未配置 NAS 浏览",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                    } description: {
                        Text("请先配置 QNAP WebDAV 本地/远程地址。")
                    } actions: {
                        Button("打开归档设置") {
                            archiveViewModel.isShowingSettings = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .navigationTitle("NAS")
                    .toolbar {
                        ToolbarItem(
                            placement: .topBarTrailing
                        ) {
                            Button {
                                archiveViewModel.isShowingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("设置")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $archiveViewModel.isShowingSettings) {
            SettingsView()
                .environmentObject(archiveViewModel)
        }
    }
}
