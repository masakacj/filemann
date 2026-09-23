import CryptoKit
import ImageIO
import SwiftUI
import UIKit

struct RemoteMediaThumbnailView: View {
    let entry: RemoteMediaEntry
    let settings: SMBSettings
    let password: String
    let baseURLString: String?
    let targetSize: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)

            if entry.kind == .folder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(
                    systemName: entry.kind == .video
                        ? "play.rectangle.fill"
                        : "photo"
                )
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            }

            if entry.kind == .video {
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
        .task(id: cacheKey) {
            guard entry.kind == .image,
                  let baseURLString else {
                return
            }

            image = await RemoteThumbnailStore.shared.load(
                entry: entry,
                settings: settings,
                password: password,
                baseURLString: baseURLString,
                maxPixelSize: max(
                    320,
                    Int(max(targetSize.width, targetSize.height) * 2)
                )
            )
        }
    }

    private var cacheKey: String {
        "\(baseURLString ?? "")|\(entry.path)|\(entry.size)"
    }
}

final class RemoteThumbnailStore: @unchecked Sendable {
    static let shared = RemoteThumbnailStore()

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        cacheDirectory = caches
            .appendingPathComponent("FileMann", isDirectory: true)
            .appendingPathComponent("RemoteThumbnails", isDirectory: true)

        try? fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        memory.countLimit = 180
    }

    func load(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String,
        maxPixelSize: Int
    ) async -> UIImage? {
        let key = cacheKey(
            baseURLString: baseURLString,
            path: entry.path,
            size: entry.size
        )

        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }

        let diskURL = cacheDirectory
            .appendingPathComponent(key)
            .appendingPathExtension("jpg")

        if let image = UIImage(contentsOfFile: diskURL.path) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        do {
            let service = try WebDAVArchiveService(
                settings: settings,
                password: password,
                baseURLString: baseURLString
            )
            let temporary = try await service.downloadToTemporaryFile(
                path: entry.path
            )

            guard let image = Self.downsample(
                url: temporary,
                maxPixelSize: maxPixelSize
            ) else {
                return nil
            }

            memory.setObject(image, forKey: key as NSString)

            if let data = image.jpegData(compressionQuality: 0.78) {
                try? data.write(to: diskURL, options: [.atomic])
            }

            return image
        } catch {
            return nil
        }
    }

    private func cacheKey(
        baseURLString: String,
        path: String,
        size: Int64
    ) -> String {
        let value = "\(baseURLString)|\(path)|\(size)"
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func downsample(
        url: URL,
        maxPixelSize: Int
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
