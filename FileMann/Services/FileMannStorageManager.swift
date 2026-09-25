import Foundation

struct FileMannStorageSnapshot: Sendable, Equatable {
    var localMediaBytes: Int64 = 0
    var shortcutInboxBytes: Int64 = 0
    var cacheBytes: Int64 = 0
    var metadataBytes: Int64 = 0
    var temporaryBytes: Int64 = 0

    var otherBytes: Int64 {
        metadataBytes + temporaryBytes
    }

    var managedBytes: Int64 {
        localMediaBytes +
            shortcutInboxBytes +
            cacheBytes +
            otherBytes
    }
}

actor FileMannStorageManager {
    static let shared = FileMannStorageManager()

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

        return FileMannStorageSnapshot(
            localMediaBytes: localMedia,
            shortcutInboxBytes: inbox,
            cacheBytes: cache,
            metadataBytes: edits + imports,
            temporaryBytes: temporary
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
                    .skipsHiddenFiles,
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
