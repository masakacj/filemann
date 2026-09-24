import Foundation

enum FileMannCachePolicy {
    static let allowedLimitMB = [
        256,
        512,
        1024,
        2048,
        4096
    ]

    static let defaultLimitMB = 512

    private static let limitKey =
        "filemann.cache.maxSizeMB"

    static var limitMB: Int {
        get {
            let stored = UserDefaults.standard.integer(
                forKey: limitKey
            )
            return allowedLimitMB.contains(stored)
                ? stored
                : defaultLimitMB
        }
        set {
            let normalized = allowedLimitMB.min {
                abs($0 - newValue) < abs($1 - newValue)
            } ?? defaultLimitMB
            UserDefaults.standard.set(
                normalized,
                forKey: limitKey
            )
        }
    }

    static var limitBytes: Int64 {
        Int64(limitMB) * 1024 * 1024
    }
}

actor FileMannCacheManager {
    static let shared = FileMannCacheManager()

    private struct CacheFile {
        let url: URL
        let size: Int64
        let lastUsedAt: Date
    }

    private let fileManager = FileManager.default
    private var didPrepareAtLaunch = false
    private var lastEnforcedAt = Date.distantPast

    func prepareAtLaunch() {
        guard !didPrepareAtLaunch else {
            return
        }

        didPrepareAtLaunch = true

        // Older builds used URLSessionConfiguration.default for WebDAV.
        // Purge any legacy HTTP disk cache once; current WebDAV sessions
        // explicitly bypass URLCache.
        URLCache.shared.removeAllCachedResponses()
        enforceLimit(force: true)
    }

    func currentSizeBytes() -> Int64 {
        let fileBytes = cacheFiles().reduce(Int64(0)) {
            $0 + $1.size
        }

        return fileBytes +
            Int64(URLCache.shared.currentDiskUsage)
    }

    @discardableResult
    func clearAllCache() -> Int64 {
        let before = currentSizeBytes()

        URLCache.shared.removeAllCachedResponses()

        for file in cacheFiles() {
            try? fileManager.removeItem(at: file.url)
        }

        lastEnforcedAt = Date()
        return max(0, before - currentSizeBytes())
    }

    func enforceLimit(force: Bool = false) {
        let now = Date()
        if !force,
           now.timeIntervalSince(lastEnforcedAt) < 20 {
            return
        }
        lastEnforcedAt = now

        let limit = FileMannCachePolicy.limitBytes
        var files = cacheFiles()
        var total = files.reduce(Int64(0)) {
            $0 + $1.size
        }

        let legacyURLCacheBytes =
            Int64(URLCache.shared.currentDiskUsage)
        total += legacyURLCacheBytes

        guard total > limit else {
            return
        }

        if legacyURLCacheBytes > 0 {
            URLCache.shared.removeAllCachedResponses()
            total -= legacyURLCacheBytes
        }

        guard total > limit else {
            return
        }

        // Leave headroom so browsing does not trigger a full scan on
        // every new thumbnail. Files touched in the last 30 seconds are
        // protected so an image being decoded is not removed underneath it.
        let target = limit * 9 / 10
        let protectedSince =
            now.addingTimeInterval(-30)

        files.sort {
            $0.lastUsedAt < $1.lastUsedAt
        }

        for file in files
            where file.lastUsedAt < protectedSince {
            try? fileManager.removeItem(at: file.url)
            total -= file.size

            if total <= target {
                break
            }
        }
    }

    private func cacheFiles() -> [CacheFile] {
        guard let root = try? cacheRootDirectory(),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentAccessDateKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var result: [CacheFile] = []

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentAccessDateKey,
                    .contentModificationDateKey
                ]
            ),
            values.isRegularFile == true else {
                continue
            }

            let accessed =
                values.contentAccessDate ?? .distantPast
            let modified =
                values.contentModificationDate ?? .distantPast

            result.append(
                CacheFile(
                    url: url,
                    size: Int64(values.fileSize ?? 0),
                    lastUsedAt: max(accessed, modified)
                )
            )
        }

        return result
    }

    private func cacheRootDirectory() throws -> URL {
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = caches.appendingPathComponent(
            "FileMann",
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
