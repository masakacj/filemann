import AVFoundation
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

    @Environment(\.displayScale) private var displayScale
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
                            .background(
                                .ultraThinMaterial,
                                in: Circle()
                            )
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(
            "remote-thumbnail-\(entry.name)"
        )
        .accessibilityValue(
            image == nil ? "loading" : "loaded"
        )
        .task(id: cacheKey) {
            guard entry.kind == .image ||
                    entry.kind == .video,
                  let baseURLString else {
                return
            }

            let pixelSize = max(
                180,
                Int(
                    max(
                        targetSize.width,
                        targetSize.height
                    ) * displayScale * 1.15
                )
            )

            image = await RemoteThumbnailStore.shared.load(
                entry: entry,
                settings: settings,
                password: password,
                baseURLString: baseURLString,
                maxPixelSize: pixelSize
            )
        }
    }

    private var cacheKey: String {
        [
            baseURLString ?? "",
            entry.path,
            String(entry.size),
            String(
                Int(
                    max(
                        targetSize.width,
                        targetSize.height
                    ) * displayScale
                )
            )
        ].joined(separator: "|")
    }
}

actor RemoteThumbnailGate {
    static let shared = RemoteThumbnailGate(limit: 4)

    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.resume()
        } else {
            running = max(0, running - 1)
        }
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
            .appendingPathComponent(
                "FileMann",
                isDirectory: true
            )
            .appendingPathComponent(
                "RemoteThumbnails",
                isDirectory: true
            )

        try? fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        memory.countLimit = 240
    }

    func cachedImage(
        entry: RemoteMediaEntry,
        baseURLString: String,
        maxPixelSize: Int
    ) -> UIImage? {
        let bucket = pixelBucket(maxPixelSize)
        let key = cacheKey(
            baseURLString: baseURLString,
            path: entry.path,
            size: entry.size,
            pixelBucket: bucket
        )

        if let cached = memory.object(
            forKey: key as NSString
        ) {
            return cached
        }

        let diskURL = thumbnailDiskURL(key: key)
        guard let image = UIImage(
            contentsOfFile: diskURL.path
        ) else {
            return nil
        }

        memory.setObject(
            image,
            forKey: key as NSString
        )
        return image
    }

    func load(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String,
        maxPixelSize: Int
    ) async -> UIImage? {
        let bucket = pixelBucket(maxPixelSize)
        let key = cacheKey(
            baseURLString: baseURLString,
            path: entry.path,
            size: entry.size,
            pixelBucket: bucket
        )

        if let cached = memory.object(
            forKey: key as NSString
        ) {
            return cached
        }

        let diskURL = thumbnailDiskURL(key: key)
        if let image = UIImage(
            contentsOfFile: diskURL.path
        ) {
            memory.setObject(
                image,
                forKey: key as NSString
            )
            return image
        }

        await RemoteThumbnailGate.shared.acquire()
        defer {
            Task {
                await RemoteThumbnailGate.shared.release()
            }
        }

        if let cached = memory.object(
            forKey: key as NSString
        ) {
            return cached
        }

        let image: UIImage?
        switch entry.kind {
        case .image:
            image = await loadImageThumbnail(
                entry: entry,
                settings: settings,
                password: password,
                baseURLString: baseURLString,
                maxPixelSize: bucket
            )

        case .video:
            image = await loadVideoThumbnail(
                entry: entry,
                settings: settings,
                password: password,
                baseURLString: baseURLString,
                maxPixelSize: bucket
            )

        default:
            image = nil
        }

        guard let image else {
            return nil
        }

        memory.setObject(
            image,
            forKey: key as NSString
        )

        if let data = image.jpegData(
            compressionQuality: 0.74
        ) {
            try? data.write(
                to: diskURL,
                options: [.atomic]
            )
        }

        return image
    }

    private func loadImageThumbnail(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String,
        maxPixelSize: Int
    ) async -> UIImage? {
        if let original = RemoteOriginalImageCache.shared.cachedURL(
            entry: entry,
            baseURLString: baseURLString
        ) {
            return Self.downsample(
                url: original,
                maxPixelSize: maxPixelSize
            )
        }

        do {
            let service = try WebDAVArchiveService(
                settings: settings,
                password: password,
                baseURLString: baseURLString
            )

            let stages = [
                128 * 1024,
                512 * 1024,
                2 * 1024 * 1024,
                6 * 1024 * 1024
            ]

            var accumulated = Data()
            var offset: Int64 = 0

            for target in stages {
                let cappedTarget = min(
                    Int64(target),
                    max(1, entry.size)
                )

                let needed = Int(
                    max(
                        0,
                        cappedTarget - Int64(accumulated.count)
                    )
                )

                if needed > 0 {
                    let chunk = try await service.downloadRangeData(
                        path: entry.path,
                        start: offset,
                        length: needed
                    )

                    guard !chunk.isEmpty else {
                        break
                    }

                    accumulated.append(chunk)
                    offset += Int64(chunk.count)
                }

                if let image = Self.downsampleIncremental(
                    data: accumulated,
                    isFinal: Int64(accumulated.count) >= entry.size,
                    maxPixelSize: maxPixelSize
                ) {
                    return image
                }

                if Int64(accumulated.count) >= entry.size {
                    break
                }
            }

            if entry.size > 0,
               entry.size <= 12 * 1024 * 1024 {
                let temporary = try await service
                    .downloadToTemporaryFile(
                        path: entry.path
                    )

                return Self.downsample(
                    url: temporary,
                    maxPixelSize: maxPixelSize
                )
            }
        } catch {
            return nil
        }

        return nil
    }

    private func loadVideoThumbnail(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String,
        maxPixelSize: Int
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let loader = WebDAVAssetResourceLoader(
                path: entry.path,
                settings: settings,
                password: password,
                preferredBaseURLString: baseURLString
            )

            let virtualURL = URL(
                string: "filemann-thumb://video/\(UUID().uuidString)"
            )!

            let asset = AVURLAsset(url: virtualURL)
            let queue = DispatchQueue(
                label: "FileMann.RemoteThumbnail.Video"
            )

            asset.resourceLoader.setDelegate(
                loader,
                queue: queue
            )

            let generator = AVAssetImageGenerator(
                asset: asset
            )
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: maxPixelSize,
                height: maxPixelSize
            )
            generator.requestedTimeToleranceBefore = CMTime(
                seconds: 0.35,
                preferredTimescale: 600
            )
            generator.requestedTimeToleranceAfter = CMTime(
                seconds: 0.35,
                preferredTimescale: 600
            )

            let time = CMTime(
                seconds: 0.25,
                preferredTimescale: 600
            )

            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: time)]
            ) { _, image, _, _, _ in
                _ = loader
                _ = asset
                _ = generator

                if let image {
                    continuation.resume(
                        returning: UIImage(
                            cgImage: image
                        )
                    )
                } else {
                    continuation.resume(
                        returning: nil
                    )
                }
            }
        }
    }

    private func pixelBucket(
        _ requested: Int
    ) -> Int {
        let value = max(160, requested)
        let buckets = [
            192,
            256,
            320,
            480,
            640,
            960,
            1280,
            1600
        ]

        return buckets.first {
            $0 >= value
        } ?? 1600
    }

    private func thumbnailDiskURL(
        key: String
    ) -> URL {
        cacheDirectory
            .appendingPathComponent(key)
            .appendingPathExtension("jpg")
    }

    private func cacheKey(
        baseURLString: String,
        path: String,
        size: Int64,
        pixelBucket: Int
    ) -> String {
        let value = [
            baseURLString,
            path,
            String(size),
            String(pixelBucket)
        ].joined(separator: "|")

        let digest = SHA256.hash(
            data: Data(value.utf8)
        )

        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func downsampleIncremental(
        data: Data,
        isFinal: Bool,
        maxPixelSize: Int
    ) -> UIImage? {
        guard !data.isEmpty else {
            return nil
        }

        let source = CGImageSourceCreateIncremental(
            nil
        )

        CGImageSourceUpdateData(
            source,
            data as CFData,
            isFinal
        )

        return thumbnail(
            source: source,
            maxPixelSize: maxPixelSize
        )
    }

    static func downsample(
        url: URL,
        maxPixelSize: Int
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [
                kCGImageSourceShouldCache: false
            ] as CFDictionary
        ) else {
            return nil
        }

        return thumbnail(
            source: source,
            maxPixelSize: maxPixelSize
        )
    }

    private static func thumbnail(
        source: CGImageSource,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways:
                true,
            kCGImageSourceCreateThumbnailWithTransform:
                true,
            kCGImageSourceThumbnailMaxPixelSize:
                maxPixelSize,
            kCGImageSourceShouldCacheImmediately:
                true
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

final class RemoteOriginalImageCache: @unchecked Sendable {
    static let shared = RemoteOriginalImageCache()

    private let fileManager = FileManager.default
    private let directory: URL

    private init() {
        let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]

        directory = caches
            .appendingPathComponent(
                "FileMann",
                isDirectory: true
            )
            .appendingPathComponent(
                "RemoteImages",
                isDirectory: true
            )

        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func cachedURL(
        entry: RemoteMediaEntry,
        baseURLString: String
    ) -> URL? {
        let url = diskURL(
            entry: entry,
            baseURLString: baseURLString
        )

        guard fileManager.fileExists(
            atPath: url.path
        ) else {
            return nil
        }

        return url
    }

    func store(
        temporaryURL: URL,
        entry: RemoteMediaEntry,
        baseURLString: String
    ) -> URL {
        let destination = diskURL(
            entry: entry,
            baseURLString: baseURLString
        )

        if !fileManager.fileExists(
            atPath: destination.path
        ) {
            try? fileManager.copyItem(
                at: temporaryURL,
                to: destination
            )
        }

        trimCacheIfNeeded()
        return destination
    }

    private func diskURL(
        entry: RemoteMediaEntry,
        baseURLString: String
    ) -> URL {
        let value = [
            baseURLString,
            entry.path,
            String(entry.size)
        ].joined(separator: "|")

        let digest = SHA256.hash(
            data: Data(value.utf8)
        )

        let key = digest.map {
            String(format: "%02x", $0)
        }.joined()

        let ext = (
            entry.name as NSString
        ).pathExtension

        return directory
            .appendingPathComponent(key)
            .appendingPathExtension(
                ext.isEmpty ? "img" : ext
            )
    }

    private func trimCacheIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let values: [(URL, Int64, Date)] = files.compactMap {
            url in
            guard let resources = try? url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey
                ]
            ) else {
                return nil
            }

            return (
                url,
                Int64(resources.fileSize ?? 0),
                resources.contentModificationDate
                    ?? .distantPast
            )
        }

        var total = values.reduce(Int64(0)) {
            $0 + $1.1
        }

        let highWater: Int64 =
            640 * 1024 * 1024
        let lowWater: Int64 =
            480 * 1024 * 1024

        guard total > highWater else {
            return
        }

        for value in values.sorted(
            by: { $0.2 < $1.2 }
        ) {
            try? fileManager.removeItem(
                at: value.0
            )
            total -= value.1

            if total <= lowWater {
                break
            }
        }
    }
}
