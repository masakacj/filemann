import UIKit
import UniformTypeIdentifiers

/// Native Photos / Files share-sheet receiver.
/// Uses one App Group staging location, never the FileMann private library.
/// When the provider gives a same-volume temporary file, a hard link avoids
/// copying its bytes; otherwise one temporary staging copy is unavoidable.
final class ShareViewController: UIViewController {
    private let groupID = "group.com.masakacj.filemann"
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
        case noGroup
        case noMedia
        case providerFailed

        var errorDescription: String? {
            switch self {
            case .noGroup:
                return "签名缺少 group.com.masakacj.filemann App Group 权限"
            case .noMedia: return "没有可传输的图片或视频"
            case .providerFailed: return "无法读取分享的文件"
            }
        }
    }

    private func importAttachments() async throws -> Int {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            throw ShareError.noGroup
        }
        let inbox = group.appendingPathComponent(
            "Incoming-Share", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true
        )

        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        var saved = 0

        for provider in providers {
            let identifier: String?
            if provider.hasItemConformingToTypeIdentifier(
                UTType.movie.identifier
            ) {
                identifier = UTType.movie.identifier
            } else if provider.hasItemConformingToTypeIdentifier(
                UTType.image.identifier
            ) {
                identifier = UTType.image.identifier
            } else {
                identifier = nil
            }
            guard let identifier else { continue }
            let destination = inbox.appendingPathComponent(
                UUID().uuidString.lowercased() + "__" +
                    safeName(provider.suggestedName ?? "shared-media")
            )

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) {
                    url, error in
                    guard let url else {
                        continuation.resume(
                            throwing: error ?? ShareError.providerFailed
                        )
                        return
                    }
                    do {
                        // A hard link only adds a filesystem reference if the
                        // provider and shared container reside on one volume.
                        do {
                            try FileManager.default.linkItem(
                                at: url, to: destination
                            )
                        } catch {
                            try FileManager.default.copyItem(
                                at: url, to: destination
                            )
                        }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            saved += 1
        }
        return saved
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
