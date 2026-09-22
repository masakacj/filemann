import QuickLookThumbnailing
import SwiftUI
import UIKit

struct MediaThumbnailView: View {
    let item: MediaItem
    let targetSize: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind == .video ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if item.kind == .video {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .clipped()
        .task(id: item.id) {
            image = await thumbnail()
        }
    }

    private func thumbnail() async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: targetSize,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }
}
