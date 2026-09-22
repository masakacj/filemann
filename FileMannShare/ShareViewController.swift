import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        titleLabel.text = "保存到 FileMann"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        detailLabel.text = "正在导入图片和视频…"
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        preferredContentSize = CGSize(width: 380, height: 220)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        Task { @MainActor in
            await importSharedItems()
        }
    }

    @MainActor
    private func importSharedItems() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            finish(message: "没有可导入的图片或视频", success: false)
            return
        }

        var imported = 0
        var failures = 0

        for (index, provider) in providers.enumerated() {
            detailLabel.text = "正在保存 (index + 1) / (providers.count)…"

            do {
                try await importProvider(provider)
                imported += 1
            } catch {
                failures += 1
            }
        }

        if imported > 0 {
            FileMannShared.noteLibraryChanged()
        }

        if failures == 0 {
            finish(message: "已保存 (imported) 个项目", success: true)
        } else {
            finish(message: "已保存 (imported) 个，失败 (failures) 个", success: imported > 0)
        }
    }

    private func importProvider(_ provider: NSItemProvider) async throws {
        let typeIdentifier: String
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            typeIdentifier = UTType.movie.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
            typeIdentifier = UTType.video.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            typeIdentifier = UTType.image.identifier
        } else {
            throw NSError(
                domain: "FileMannShare",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "不支持的媒体类型"]
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sourceURL else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "FileMannShare",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取共享文件"]
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

                    try FileManager.default.copyItem(at: sourceURL, to: destination)

                    if let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                       let modificationDate = attributes[.modificationDate] as? Date {
                        try? FileManager.default.setAttributes(
                            [.modificationDate: modificationDate],
                            ofItemAtPath: destination.path
                        )
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    private func finish(message: String, success: Bool) {
        spinner.stopAnimating()
        detailLabel.text = message
        detailLabel.textColor = success ? .secondaryLabel : .systemRed

        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
