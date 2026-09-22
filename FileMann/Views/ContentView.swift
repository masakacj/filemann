import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MediaLibraryView()
                .tabItem {
                    Label("媒体", systemImage: "photo.on.rectangle.angled")
                }

            ArchiveView()
                .tabItem {
                    Label("归档", systemImage: "externaldrive")
                }
        }
    }
}
