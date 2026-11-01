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

                let name = provider.suggestedName ?? "shared-media"
                let fileName: String
                if (name as NSString).pathExtension.isEmpty {
                    let ext = UTType(identifier)?
                        .preferredFilenameExtension ?? "bin"
                    fileName = name + "." + ext
                } else {
                    fileName = name
                }
                let destination = inbox.appendingPathComponent(
                    UUID().uuidString.lowercased() + "__" +
                        safeName(fileName)
                )

                // Ask the provider for in-place access first. This avoids a
                // Photos export copy when supported. NSFileCoordinator is
                // required even if the provider supplies a temporary file.
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    provider.loadInPlaceFileRepresentation(
                        forTypeIdentifier: identifier
                    ) { url, _, error in
                        guard let url else {
                            continuation.resume(
                                throwing: error ?? ShareError.providerFailed
                            )
                            return
                        }

                        let scoped = url.startAccessingSecurityScopedResource()
                        defer {
                            if scoped { url.stopAccessingSecurityScopedResource() }
                        }
                        var coordinationError: NSError?
                        var transferError: Error?

                        NSFileCoordinator(filePresenter: nil).coordinate(
                            readingItemAt: url,
                            options: [],
                            error: &coordinationError
                        ) { source in
                            do {
                                // Same-volume hard links share data blocks.
                                // Copy only when the provider or sandbox
                                // disallows a hard link.
                                do {
                                    try FileManager.default.linkItem(
                                        at: source, to: destination
                                    )
                                } catch {
                                    try FileManager.default.copyItem(
                                        at: source, to: destination
                                    )
                                }
                            } catch {
                                transferError = error
                            }
                        }

                        if let issue = transferError ?? coordinationError {
                            try? FileManager.default.removeItem(
                                at: destination
                            )
                            continuation.resume(throwing: issue)
                        } else {
                            continuation.resume()
                        }
                    }
                }
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

    private func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._- ")
        )
        let result = String(
            name.unicodeScalars.map {
                allowed.contains($0) ? Character($0) : "_"
            }
        )
        return String(result.prefix(160)).isEmpty ? "media" : result
    }
}
