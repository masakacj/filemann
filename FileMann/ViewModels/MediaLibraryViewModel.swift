import Foundation

private struct MediaLibraryScanResult: Sendable {
    let items: [MediaItem]
    let externalFolderName: String?
    let externalError: String?
}

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    struct InboxImportResult: Sendable {
        var importedCount = 0
        var importedBytes: Int64 = 0
        var unsupportedCount = 0
        var failedCount = 0
        var errorDescription: String?
    }

    @Published var items: [MediaItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var isSelectionMode = false
    @Published var isLoading = false
    @Published var isImportingInbox = false
    @Published var inboxImportProgress = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var externalFolderName =
        FileMannShared.externalFolderDisplayName()
    @Published var externalFolderError: String?

    private var lastGeneration = -1

    func refresh(force: Bool = false) {
        let generation = FileMannShared.currentGeneration()
        if !force &&
            generation == lastGeneration &&
            !items.isEmpty {
            return
        }

        lastGeneration = generation
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let snapshot = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try Self.scanLibrary()
                }.value

                items = snapshot.items
                selectedIDs.formIntersection(
                    Set(snapshot.items.map(\.id))
                )
                externalFolderName =
                    snapshot.externalFolderName
                externalFolderError =
                    snapshot.externalError

                if let externalError =
                    snapshot.externalError {
                    statusMessage =
                        "外部文件夹不可用：\(externalError)。可在“更多”中重新选择。"
                }
            } catch {
                errorMessage = error.localizedDescription
                items = []
            }
            isLoading = false
        }
    }

    func mapExternalFolder(_ url: URL) {
        do {
            try FileMannShared.setExternalFolder(url)
            FileMannShared.noteLibraryChanged()
            externalFolderName =
                FileMannShared.externalFolderDisplayName()
            externalFolderError = nil
            statusMessage =
                "已映射外部文件夹“\(externalFolderName ?? url.lastPathComponent)”；文件保持在原位置，不会复制进 FileMann。"
            refresh(force: true)
        } catch {
            externalFolderError = error.localizedDescription
            statusMessage =
                "外部文件夹映射失败：\(error.localizedDescription)"
        }
    }

    func clearExternalFolder() {
        let oldName = externalFolderName
        FileMannShared.clearExternalFolder()
        FileMannShared.noteLibraryChanged()
        externalFolderName = nil
        externalFolderError = nil
        statusMessage = oldName.map {
            "已取消映射“\($0)”；外部文件没有被删除。"
        }
        refresh(force: true)
    }

    func importInboxAndRefresh(
        showStatus: Bool = true
    ) {
        guard !isImportingInbox else { return }

        isImportingInbox = true
        inboxImportProgress =
            "正在检查旧 Shortcut Inbox…"

        Task {
            let result = await Task.detached(
                priority: .userInitiated
            ) {
                Self.consumeShortcutInbox()
            }.value

            if result.importedCount > 0 {
                FileMannShared.noteLibraryChanged()
            }

            if showStatus,
               result.importedCount > 0 ||
               result.unsupportedCount > 0 ||
               result.failedCount > 0 ||
               result.errorDescription != nil {
                var parts: [String] = []

                if result.importedCount > 0 {
                    parts.append(
                        "旧 Shortcut Inbox 已导入 \(result.importedCount) 个 · \(ByteFormat.string(result.importedBytes))"
                    )
                }
                if result.unsupportedCount > 0 {
                    parts.append(
                        "跳过 \(result.unsupportedCount) 个非图片/视频文件"
                    )
                }
                if result.failedCount > 0 {
                    parts.append(
                        "失败 \(result.failedCount) 个"
                    )
                }
                if let errorDescription =
                    result.errorDescription {
                    parts.append(errorDescription)
                }

                statusMessage =
                    parts.joined(separator: "；")
            }

            inboxImportProgress = ""
            isImportingInbox = false
            refresh(force: true)
        }
    }

    func toggleSelection(_ item: MediaItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func selectedItems() -> [MediaItem] {
        items.filter {
            selectedIDs.contains($0.id)
        }
    }

    func deleteSelected() {
        let targets = selectedItems()
        var failedCount = 0

        for item in targets {
            do {
                try FileManager.default.removeItem(
                    at: item.url
                )
                FileMannShared.removeCompanionFiles(
                    for: item.url
                )
            } catch {
                failedCount += 1
            }
        }

        FileMannShared.noteLibraryChanged()
        selectedIDs.removeAll()

        if failedCount > 0 {
            statusMessage =
                "有 \(failedCount) 个文件删除失败，请检查外部文件夹权限。"
        }

        refresh(force: true)
    }

    private nonisolated static func scanLibrary()
        throws -> MediaLibraryScanResult {
        var urls: [URL] = []

        let localDirectory =
            try FileMannShared.mediaDirectory()
        urls.append(
            contentsOf: contentsOfMediaDirectory(
                localDirectory
            )
        )

        var externalName =
            FileMannShared.externalFolderDisplayName()
        var externalError: String?

        if FileMannShared.hasExternalFolder() {
            do {
                if let externalDirectory =
                    try FileMannShared
                        .externalFolderDirectory() {
                    externalName =
                        externalDirectory.lastPathComponent
                    urls.append(
                        contentsOf: contentsOfMediaDirectory(
                            externalDirectory
                        )
                    )
                }
            } catch {
                externalError =
                    error.localizedDescription
            }
        }

        var seen: Set<String> = []
        let items = urls
            .compactMap(MediaItem.init(url:))
            .filter { item in
                seen.insert(
                    item.url.standardizedFileURL.path
                ).inserted
            }
            .sorted {
                $0.modifiedAt > $1.modifiedAt
            }

        return MediaLibraryScanResult(
            items: items,
            externalFolderName: externalName,
            externalError: externalError
        )
    }

    private nonisolated static func contentsOfMediaDirectory(
        _ directory: URL
    ) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private nonisolated static func consumeShortcutInbox()
        -> InboxImportResult {
        var result = InboxImportResult()

        do {
            let inbox =
                try FileMannShared.inboxDirectory()
            let urls =
                try FileManager.default.contentsOfDirectory(
                    at: inbox,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .contentModificationDateKey
                    ],
                    options: [.skipsHiddenFiles]
                )

            for sourceURL in urls {
                do {
                    let values =
                        try sourceURL.resourceValues(
                            forKeys: [
                                .isRegularFileKey,
                                .fileSizeKey,
                                .contentModificationDateKey
                            ]
                        )

                    guard
                        values.isRegularFile == true
                    else {
                        continue
                    }

                    guard
                        FileMannShared
                            .isSupportedMediaFile(
                                sourceURL
                            )
                    else {
                        result.unsupportedCount += 1
                        continue
                    }

                    let sourceSize =
                        Int64(values.fileSize ?? 0)
                    guard sourceSize > 0 else {
                        result.failedCount += 1
                        continue
                    }

                    let destination =
                        try FileMannShared
                            .uniqueDestination(
                                suggestedName:
                                    sourceURL
                                        .lastPathComponent,
                                sourceURL: sourceURL,
                                typeIdentifier: nil
                            )

                    try FileManager.default.moveItem(
                        at: sourceURL,
                        to: destination
                    )

                    let destinationValues =
                        try destination.resourceValues(
                            forKeys: [.fileSizeKey]
                        )
                    let destinationSize =
                        Int64(
                            destinationValues.fileSize ?? 0
                        )

                    guard
                        destinationSize == sourceSize
                    else {
                        if !FileManager.default
                            .fileExists(
                                atPath: sourceURL.path
                            ) {
                            try? FileManager.default
                                .moveItem(
                                    at: destination,
                                    to: sourceURL
                                )
                        }
                        result.failedCount += 1
                        continue
                    }

                    if let modifiedAt =
                        values.contentModificationDate {
                        try? FileManager.default
                            .setAttributes(
                                [
                                    .modificationDate:
                                        modifiedAt
                                ],
                                ofItemAtPath:
                                    destination.path
                            )
                    }

                    try? FileMannShared
                        .saveImportMetadata(
                            MediaImportMetadata(
                                source: .shortcut
                            ),
                            for: destination
                        )

                    result.importedCount += 1
                    result.importedBytes +=
                        destinationSize
                } catch {
                    result.failedCount += 1
                }
            }
        } catch {
            result.errorDescription =
                "Inbox 读取失败：\(error.localizedDescription)"
        }

        return result
    }
}
