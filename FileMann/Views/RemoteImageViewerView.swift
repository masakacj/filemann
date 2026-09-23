import ImageIO
import SwiftUI
import UIKit

struct RemoteImageViewerView: View {
    let entry: RemoteMediaEntry
    let settings: SMBSettings
    let password: String
    let baseURLString: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var isLoadingOriginal = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea(edges: .horizontal)
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法读取远程图片",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            } else {
                ProgressView("读取远程图片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Button("完成") {
                        dismiss()
                    }

                    Spacer()

                    Text(entry.name)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    if isLoadingOriginal,
                       image != nil {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(width: 44)
                    } else {
                        Color.clear
                            .frame(width: 44)
                    }
                }
                .foregroundStyle(.white)
                .padding()
                .background(.black.opacity(0.45))

                Spacer()
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        if let cached = RemoteOriginalImageCache.shared.cachedURL(
            entry: entry,
            baseURLString: baseURLString
        ),
           let decoded = Self.decodeImage(at: cached) {
            image = decoded
            isLoadingOriginal = false
            return
        }

        let previewPixelSize = max(
            960,
            min(
                1800,
                Int(
                    UIScreen.main.bounds.width *
                    displayScale * 1.35
                )
            )
        )

        if let preview = await RemoteThumbnailStore.shared.load(
            entry: entry,
            settings: settings,
            password: password,
            baseURLString: baseURLString,
            maxPixelSize: previewPixelSize
        ) {
            image = preview
        }

        do {
            var service = try WebDAVArchiveService(
                settings: settings,
                password: password,
                baseURLString: baseURLString
            )

            let temporary: URL
            do {
                temporary = try await service
                    .downloadToTemporaryFile(
                        path: entry.path
                    )
            } catch {
                let resolved = try await WebDAVArchiveService
                    .resolveBestBaseURL(
                        settings: settings,
                        password: password,
                        forceRemote: true
                    )

                service = try WebDAVArchiveService(
                    settings: settings,
                    password: password,
                    baseURLString: resolved
                )

                temporary = try await service
                    .downloadToTemporaryFile(
                        path: entry.path
                    )
            }

            let cached = RemoteOriginalImageCache.shared.store(
                temporaryURL: temporary,
                entry: entry,
                baseURLString: service.baseURLString
            )

            if let decoded = Self.decodeImage(
                at: cached
            ) {
                image = decoded
            } else if image == nil {
                errorMessage = "图片格式无法解码"
            }
        } catch {
            if image == nil {
                errorMessage = error.localizedDescription
            }
        }

        isLoadingOriginal = false
    }

    private static func decodeImage(
        at url: URL
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [
                kCGImageSourceShouldCache: false
            ] as CFDictionary
        ) else {
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [
                kCGImageSourceShouldCacheImmediately:
                    true
            ] as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
