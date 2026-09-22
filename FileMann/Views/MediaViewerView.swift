import SwiftUI

struct MediaViewerView: View {
    let item: MediaItem

    var body: some View {
        switch item.kind {
        case .image:
            PhotoEditorView(url: item.url)
        case .video:
            VideoEditorView(url: item.url)
        }
    }
}
