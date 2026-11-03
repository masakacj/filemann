import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Separate from the iOS Photos share-sheet extension. PHPicker's .current
/// preference asks Photos for the existing HEIC/HEIF representation instead
/// of automatically generating a compatibility JPEG. No full photo library
/// authorization is required to choose individual assets.
struct OriginalPhotosPicker: UIViewControllerRepresentable {
    let onProgress: (Int, Int) -> Void
    let onBatchStaged: () -> Void
    let onFinish: (Int, Int, [String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress,
            onBatchStaged: onBatchStaged,
            onFinish: onFinish
        )
    }

    func makeUIViewController(
        context: Context
    ) -> PHPickerViewController {
        var config = PHPickerConfiguration(
            photoLibrary: PHPhotoLibrary.shared()
        )
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ controller: PHPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onProgress: (Int, Int) -> Void
        let onBatchStaged: () -> Void
        let onFinish: (Int, Int, [String]) -> Void

        init(
            onProgress: @escaping (Int, Int) -> Void,
            onBatchStaged: @escaping () -> Void,
            onFinish: @escaping (Int, Int, [String]) -> Void
        ) {
            self.onProgress = onProgress
            self.onBatchStaged = onBatchStaged
            self.onFinish = onFinish
        }

        private func originalFilenameIfAccessible(
            for result: PHPickerResult
        ) -> String? {
            let authorization = PHPhotoLibrary.authorizationStatus(
                for: .readWrite
            )
            guard authorization == .authorized ||
                    authorization == .limited,
                  let identifier = result.assetIdentifier,
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier],
                    options: nil
                  ).firstObject else {
                return nil
            }
            let resources = PHAssetResource.assetResources(for: asset)
            return resources.first(where: {
                $0.type == .photo || $0.type == .video
            })?.originalFilename
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            // The providers remain retained by this task after dismissing.
            // Never request a UIImage, which decodes/re-encodes HEIC as JPEG.
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            Task { @MainActor in
                var imported = 0
                var failed = 0
                var failures: [String] = []
                do {
                    let inbox = try FileMannShareGroup.incomingDirectory()
                    for (index, result) in results.enumerated() {
                        onProgress(index + 1, results.count)
                        do {
                            // When the user has already granted PhotoKit
                            // access, use the asset's real originalFilename.
                            // PHPicker itself remains usable without access.
                            let originalName = originalFilenameIfAccessible(
                                for: result
                            )
                            _ = try await FileMannMediaRepresentation.stageProvider(
                                result.itemProvider,
                                selectionIndex: index + 1,
                                inbox: inbox,
                                originalFilenameHint: originalName
                            )
                            imported += 1
                            if imported % 20 == 0 {
                                onBatchStaged()
                            }
                        } catch {
                            failed += 1
                            if failures.count < 3 {
                                failures.append(
                                    "第 \(index + 1) 项：" +
                                    error.localizedDescription
                                )
                            }
                        }
                    }
                } catch {
                    failed += max(1, results.count - imported)
                    failures.append(error.localizedDescription)
                }
                onBatchStaged()
                onFinish(imported, failed, failures)
            }
        }
    }
}
