import Photos
import PhotosUI
import SwiftUI

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onPick: ([PHPickerResult]) -> Void

        init(onPick: @escaping ([PHPickerResult]) -> Void) {
            self.onPick = onPick
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            picker.dismiss(animated: true) {
                self.onPick(results)
            }
        }
    }
}
