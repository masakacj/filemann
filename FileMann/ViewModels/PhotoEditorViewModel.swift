import CoreImage
import ImageIO
import UIKit

@MainActor
final class PhotoEditorViewModel: ObservableObject {
    @Published var adjustments: MediaAdjustments
    @Published var displayImage: UIImage?
    @Published var isLoading = true
    @Published var errorMessage: String?

    let url: URL

    private var sourceImage: CIImage?
    private var renderTask: Task<Void, Never>?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(url: URL) {
        self.url = url
        self.adjustments = MediaSidecarStore.load(for: url)
        loadPreview()
    }

    func reset() {
        adjustments = .neutral
        renderAndSave()
    }

    func renderAndSave() {
        renderTask?.cancel()
        let current = adjustments
        let source = sourceImage
        let context = self.context
        let url = self.url

        renderTask = Task {
            try? MediaSidecarStore.save(current, for: url)

            guard let source else { return }
            let output = MediaFilterPipeline.apply(to: source, adjustments: current)

            guard !Task.isCancelled,
                  let cg = context.createCGImage(output, from: output.extent) else {
                return
            }

            displayImage = UIImage(cgImage: cg)
        }
    }

    private func loadPreview() {
        Task {
            do {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw NSError(
                        domain: "FileMannPhoto",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "无法读取图片"]
                    )
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2400,
                    kCGImageSourceShouldCacheImmediately: true
                ]

                guard let cg = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ) else {
                    throw NSError(
                        domain: "FileMannPhoto",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "无法生成图片预览"]
                    )
                }

                let ci = CIImage(cgImage: cg)
                sourceImage = ci
                isLoading = false
                renderAndSave()
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
