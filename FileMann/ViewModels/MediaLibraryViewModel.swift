import Foundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    struct ImportedPhoto: Sendable {
        let localURL: URL
        let assetIdentifier: String?
        let bytes: Int64
    }

    @Published var items: [MediaItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var isSelectionMode = false
    @Published var isLoading = false
    @Published var isImportingPhotos = false
    @Published var photoImportProgress = ""
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var lastGeneration = -1

    func refresh(force: Bool = false) {
        let generation = FileMannShared.currentGeneration()
        if !force && generation == lastGeneration && !items.isEmpty {
            return
        }

        lastGeneration = generation
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    let directory = try FileMannShared.mediaDirectory()
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )

                    return urls
                        .compactMap(MediaItem.init(url:))
                        .sorted { $0.modifiedAt > $1.modifiedAt }
                }.value

                items = values
                selectedIDs.formIntersection(Set(values.map(\.id)))
            } catch {
                errorMessage = error.localizedDescription
                items = []
            }
            isLoading = false
        }
    }

    func importPhotoPickerResults(
        _ results: [PHPickerResult],
        deleteOriginalsAfterImport: Bool
    ) {
        guard !results.isEmpty, !isImportingPhotos else { return }

        isImportingPhotos = true
        statusMessage = nil
        photoImportProgress = "准备导入 \(results.count) 个项目…"

        Task {
            var imported: [ImportedPhoto] = []
            var failures = 0

            for (index, result) in results.enumerated() {
                photoImportProgress = "正在导入 \(index + 1) / \(results.count)…"

                do {
                    let item = try await Self.copyPickerResult(result)
                    imported.append(item)
                } catch {
                    failures += 1
                }
            }

            if !imported.isEmpty {
                FileMannShared.noteLibraryChanged()
                refresh(force: true)
            }

            let totalBytes = imported.reduce(Int64(0)) { $0 + $1.bytes }
            if failures == 0 {
                statusMessage = "已导入 \(imported.count) 个 · \(ByteFormat.string(totalBytes))"
            } else {
                statusMessage = "已导入 \(imported.count) 个 · \(ByteFormat.string(totalBytes))，失败 \(failures) 个"
            }

            if deleteOriginalsAfterImport, !imported.isEmpty {
                photoImportProgress = "等待相册删除确认…"
                await deleteImportedPhotoAssets(imported)
            }

            photoImportProgress = ""
            isImportingPhotos = false
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
        items.filter { selectedIDs.contains($0.id) }
    }

    func deleteSelected() {
        let targets = selectedItems()
        for item in targets {
            try? FileManager.default.removeItem(at: item.url)
            FileMannShared.removeCompanionFiles(for: item.url)
        }
        FileMannShared.noteLibraryChanged()
        selectedIDs.removeAll()
        refresh(force: true)
    }

    private func deleteImportedPhotoAssets(_ imported: [ImportedPhoto]) async {
        let identifiers = Array(
            Set(imported.compactMap(\.assetIdentifier))
        )

        guard !identifiers.isEmpty else {
            statusMessage = (statusMessage ?? "") + "；这些项目没有可用于清理相册原件的 PhotoKit 标识"
            return
        }

        let authorization = await Self.requestPhotoLibraryAuthorization()
        guard authorization == .authorized || authorization == .limited else {
            statusMessage = (statusMessage ?? "") + "；未获得照片库修改权限，相册原件已保留"
            return
        }

        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: nil
        )

        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        guard !assets.isEmpty else {
            statusMessage = (statusMessage ?? "") + "；当前照片权限范围内找不到对应原件，未删除"
            return
        }

        do {
            try await Self.deletePhotoAssets(assets)

            let deletedIDs = Set(assets.map(\.localIdentifier))
            for importedItem in imported {
                if let identifier = importedItem.assetIdentifier,
                   deletedIDs.contains(identifier) {
                    FileMannShared.markPhotoDeleted(for: importedItem.localURL)
                }
            }

            FileMannShared.noteLibraryChanged()
            refresh(force: true)

            if assets.count == identifiers.count {
                statusMessage = (statusMessage ?? "") + "；相册原件已移入“最近删除”"
            } else {
                statusMessage = (statusMessage ?? "") + "；已清理 \(assets.count)/\(identifiers.count) 个相册原件，其余不在当前 PhotoKit 授权范围"
            }
        } catch {
            statusMessage = (statusMessage ?? "") + "；相册删除未完成：\(error.localizedDescription)"
        }
    }

    private nonisolated static func copyPickerResult(
        _ result: PHPickerResult
    ) async throws -> ImportedPhoto {
        let provider = result.itemProvider
        let typeIdentifier = preferredTypeIdentifier(for: provider)

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ImportedPhoto, Error>) in

            provider.loadFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { sourceURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sourceURL else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "FileMannPhotos",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取相册项目"]
                        )
                    )
                    return
                }

                do {
                    let destination = try FileMannShared.uniqueDestination(
                        suggestedName: provider.suggestedName,
                        sourceURL: sourceURL,
                        typeIdentifier: typeIdentifier
                    )

                    try FileManager.default.copyItem(
                        at: sourceURL,
                        to: destination
                    )

                    let sourceAttributes = try FileManager.default.attributesOfItem(
                        atPath: sourceURL.path
                    )
                    let destinationAttributes = try FileManager.default.attributesOfItem(
                        atPath: destination.path
                    )

                    let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    let destinationSize = (destinationAttributes[.size] as? NSNumber)?.int64Value ?? 0

                    guard sourceSize == destinationSize else {
                        try? FileManager.default.removeItem(at: destination)
                        throw NSError(
                            domain: "FileMannPhotos",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "导入后的文件大小与相册提供的文件不一致"
                            ]
                        )
                    }

                    if let modificationDate = sourceAttributes[.modificationDate] as? Date {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: modificationDate],
                            ofItemAtPath: destination.path
                        )
                    }

                    try FileMannShared.saveImportMetadata(
                        MediaImportMetadata(
                            source: .photoPicker,
                            sourceAssetIdentifier: result.assetIdentifier
                        ),
                        for: destination
                    )

                    continuation.resume(
                        returning: ImportedPhoto(
                            localURL: destination,
                            assetIdentifier: result.assetIdentifier,
                            bytes: destinationSize
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func preferredTypeIdentifier(
        for provider: NSItemProvider
    ) -> String {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return UTType.movie.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
            return UTType.video.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }

        return provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
    }

    private nonisolated static func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func deletePhotoAssets(
        _ assets: [PHAsset]
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? NSError(
                            domain: "FileMannPhotos",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "照片库未完成删除"]
                        )
                    )
                }
            }
        }
    }
}
