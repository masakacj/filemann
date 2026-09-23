import ImageIO
import SwiftUI
import UIKit

struct RemoteImageViewerView: View {
    let entry: RemoteMediaEntry
    let settings: SMBSettings
    let password: String
    let baseURLString: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
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

                    Color.clear
                        .frame(width: 44)
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
        do {
            var service = try WebDAVArchiveService(
                settings: settings,
                password: password,
                baseURLString: baseURLString
            )

            let temporary: URL
            do {
                temporary = try await service.downloadToTemporaryFile(
                    path: entry.path
                )
            } catch {
                let resolved = try await WebDAVArchiveService.resolveBestBaseURL(
                    settings: settings,
                    password: password,
                    forceRemote: true
                )
                service = try WebDAVArchiveService(
                    settings: settings,
                    password: password,
                    baseURLString: resolved
                )
                temporary = try await service.downloadToTemporaryFile(
                    path: entry.path
                )
            }

            image = Self.decodeImage(at: temporary)
            if image == nil {
                errorMessage = "图片格式无法解码"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func decodeImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
