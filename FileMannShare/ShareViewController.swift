import UIKit
import UniformTypeIdentifiers

/// Native Photos / Files share-sheet receiver.
/// Uses one App Group staging location, never the FileMann private library.
/// When the provider gives a same-volume temporary file, a hard link avoids
/// copying its bytes; otherwise one temporary staging copy is unavoidable.
final class ShareViewController: UIViewController {
    private let info = UILabel()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let action = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private var isSubmitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 350, height: 260)

        let title = UILabel()
        title.text = "添加到 FileMann"
        title.font = .preferredFont(forTextStyle: .headline)

        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .subheadline)
        info.textColor = .secondaryLabel
        info.text = "将共享文件加入持久化队列。无法直接使用原文件时，会临时暂存一份，成功归档后自动清理。"

        action.setTitle("添加到传输队列", for: .normal)
        action.addTarget(self, action: #selector(beginImport), for: .touchUpInside)

        cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelImport), for: .touchUpInside)

        let controls = UIStackView(arrangedSubviews: [cancel, action, progress])
        controls.axis = .horizontal
        controls.distribution = .equalSpacing
        controls.alignment = .center

        let stack = UIStackView(arrangedSubviews: [title, info, controls])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func cancelImport() {
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "FileMannShare", code: NSUserCancelledError
            )
        )
    }

    @objc private func beginImport() {
        guard !isSubmitting else { return }
        isSubmitting = true
        action.isEnabled = false
        progress.startAnimating()
        Task { @MainActor in
            do {
                let count = try await importAttachments()
                guard count > 0 else {
                    throw ShareError.noMedia
                }
                info.text = "已加入 \(count) 个文件。打开 FileMann 后可查看并启动传输。"
                progress.stopAnimating()
                extensionContext?.completeRequest(
                    returningItems: [], completionHandler: nil
                )
            } catch {
                progress.stopAnimating()
                info.text = "未能加入队列：\(error.localizedDescription)"
                action.isEnabled = true
                isSubmitting = false
            }
        }
    }

    private enum ShareError: LocalizedError {
        case noMedia
        case providerFailed

        var errorDescription: String? {
            switch self {
            case .noMedia: return "没有可传输的图片或视频"
            case .providerFailed: return "无法读取分享的文件"
            }
        }
    }

    private func importAttachments() async throws -> Int {
        // FileMann and this extension use the same group resolved from their
        // signed provisioning profiles.
        let inbox = try FileMannShareGroup.incomingDirectory()
        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        var created: [URL] = []
        do {
            for provider in providers {
                try Task.checkCancellation()

                // Prefer HEIC/HEIF/MOV/MP4, not a converted generic image.
                let supported = provider.registeredTypeIdentifiers.filter {
                    guard let kind = UTType($0) else { return false }
                    return kind.conforms(to: .movie) ||
                        kind.conforms(to: .image)
                }
                let identifier = supported.first {
                    $0 != UTType.image.identifier &&
                        $0 != UTType.movie.identifier
                } ?? supported.first
                guard let identifier else { continue }

                let destination = try await stageMedia(
                    provider,
                    typeIdentifier: identifier,
                    inbox: inbox
                )
                created.append(destination)
            }
            return created.count
        } catch {
            // All-or-nothing staging: do not strand extra copies when one
            // of the selected photos fails or the user cancels.
            for file in created {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }
    }

    /// NSItemProvider URLs may be invalid as soon as their callback returns.
    /// Resolve the real source filename and stage the file *inside* the
    /// callback. Photos providers that do not offer an in-place URL can
    /// still supply a temporary file representation.
    private func stageMedia(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        inbox: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in

            provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, _, _ in
                if let url {
                    do {
                        let stored = try FileMannShareFileNaming.stage(
                            sourceURL: url,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier,
                            in: inbox
                        )
                        continuation.resume(returning: stored)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                provider.loadFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { temporaryURL, error in
                    guard let temporaryURL else {
                        continuation.resume(
                            throwing: error ?? ShareError.providerFailed
                        )
                        return
                    }
                    do {
                        let stored = try FileMannShareFileNaming.stage(
                            sourceURL: temporaryURL,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier,
                            in: inbox
                        )
                        continuation.resume(returning: stored)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
