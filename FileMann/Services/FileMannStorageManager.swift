import Foundation

struct FileMannStorageSnapshot: Sendable, Equatable {
    var localMediaBytes: Int64 = 0
    var shortcutInboxBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var metadataBytes: Int64 = 0
    var temporaryBytes: Int64 = 0

    // Whole-container diagnostics. These include data not created by the
    // current FileMann cache/media helpers, such as system URLSession files.
    var sandboxBytes: Int64 = 0
    var documentsBytes: Int64 = 0
    var libraryBytes: Int64 = 0
    var applicationSupportBytes: Int64 = 0
    var totalCachesBytes: Int64 = 0

    // FileMann used this shared container in early builds.
    var legacyAppGroupAvailable = false
    var legacyAppGroupBytes: Int64 = 0
    var legacyAppGroupMediaBytes: Int64 = 0

    var otherBytes: Int64 {
        metadataBytes + temporaryBytes
    }

    var managedBytes: Int64 {
        localMediaBytes +
            shortcutInboxBytes +
            cacheBytes +
            otherBytes
    }

    var systemCacheBytes: Int64 {
        max(0, totalCachesBytes - cacheBytes)
    }

    var unclassifiedSandboxBytes: Int64 {
        max(0, sandboxBytes - managedBytes)
    }
}

actor FileMannStorageManager {
    static let shared = FileMannStorageManager()

    static let legacyAppGroupID =
        "group.com.masakacj.filemann"

    private let fileManager = FileManager.default

    func snapshot() async -> FileMannStorageSnapshot {
        let localMedia = directorySize(
            try? FileMannShared.mediaDirectory()
        )
        let inbox = directorySize(
            try? FileMannShared.inboxDirectory()
        )
        let edits = directorySize(
            try? FileMannShared.sidecarDirectory()
        )
        let imports = directorySize(
            try? FileMannShared.importMetadataDirectory()
        )
        let temporary = directorySize(
            fileManager.temporaryDirectory
        )
        let cache = await FileMannCacheManager.shared
            .currentSizeBytes()

        let home = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        let documents = directoryURL(.documentDirectory)
        let library = directoryURL(.libraryDirectory)
        let appSupport =
            directoryURL(.applicationSupportDirectory)
        let caches = directoryURL(.cachesDirectory)

        let legacyGroup = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                Self.legacyAppGroupID
        )
        let legacyMedia = legacyGroup?
            .appendingPathComponent(
                "Media",
                isDirectory: true
            )

        return FileMannStorageSnapshot(
            localMediaBytes: localMedia,
            shortcutInboxBytes: inbox,
            cacheBytes: cache,
            metadataBytes: edits + imports,
            temporaryBytes: temporary,
            sandboxBytes: directorySize(home),
            documentsBytes: directorySize(documents),
            libraryBytes: directorySize(library),
            applicationSupportBytes:
                directorySize(appSupport),
            totalCachesBytes: directorySize(caches),
            legacyAppGroupAvailable:
                legacyGroup != nil,
            legacyAppGroupBytes:
                directorySize(legacyGroup),
            legacyAppGroupMediaBytes:
                directorySize(legacyMedia)
        )
    }

    @discardableResult
    func clearLocalMedia() -> Int64 {
        let media = try? FileMannShared.mediaDirectory()
        let edits = try? FileMannShared.sidecarDirectory()
        let imports =
            try? FileMannShared.importMetadataDirectory()

        let before =
            directorySize(media) +
            directorySize(edits) +
            directorySize(imports)

        removeContents(of: media)
        removeContents(of: edits)
        removeContents(of: imports)

        FileMannShared.noteLibraryChanged()

        let after =
            directorySize(media) +
            directorySize(edits) +
            directorySize(imports)

        return max(0, before - after)
    }

    @discardableResult
    func clearShortcutInbox() -> Int64 {
        let inbox = try? FileMannShared.inboxDirectory()
        let before = directorySize(inbox)

        removeContents(of: inbox)

        return max(
            0,
            before - directorySize(inbox)
        )
    }

    @discardableResult
    func clearSystemCaches() -> Int64 {
        let caches = directoryURL(.cachesDirectory)
        let before = directorySize(caches)

        URLCache.shared.removeAllCachedResponses()
        removeContents(of: caches)

        return max(
            0,
            before - directorySize(caches)
        )
    }

    @discardableResult
    func clearLegacyAppGroupMedia() -> Int64 {
        guard let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                Self.legacyAppGroupID
        ) else {
            return 0
        }

        let media = group.appendingPathComponent(
            "Media",
            isDirectory: true
        )
        let before = directorySize(media)

        removeContents(of: media)

        return max(
            0,
            before - directorySize(media)
        )
    }

    private func directoryURL(
        _ searchPath: FileManager.SearchPathDirectory
    ) -> URL? {
        try? fileManager.url(
            for: searchPath,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    private func directorySize(_ directory: URL?) -> Int64 {
        guard let directory,
              fileManager.fileExists(
                atPath: directory.path
              ),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey
                ],
                options: [
                    .skipsPackageDescendants
                ]
              ) else {
            return 0
        }

        var total: Int64 = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey
                ]
            ),
            values.isRegularFile == true else {
                continue
            }

            let bytes =
                values.totalFileAllocatedSize ??
                values.fileAllocatedSize ??
                values.fileSize ??
                0
            total += Int64(bytes)
        }

        return total
    }

    private func removeContents(of directory: URL?) {
        guard let directory,
              let contents =
                try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else {
            return
        }

        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}
