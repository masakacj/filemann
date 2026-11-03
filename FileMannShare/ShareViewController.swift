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
    private let batchProgress = UIProgressView(progressViewStyle: .default)
    private var partialImport: ShareImportSummary?

    private struct ShareImportSummary {
        var received: Int
        var imported = 0
        var awaitingNames = 0
        var unsupported = 0
        var failed = 0
        var firstErrors: [String] = []

        var hasIssues: Bool { unsupported > 0 || failed > 0 }
    }

    private func sharedProviders() -> [NSItemProvider] {
        (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(
            width: 360,
            height: sharedProviders().count > 25 ? 340 : 260
        )

        let title = UILabel()
        title.text = "添加到 FileMann"
        title.font = .preferredFont(forTextStyle: .headline)

        info.numberOfLines = 0
        info.font = .preferredFont(forTextStyle: .subheadline)
        info.textColor = .secondaryLabel
        let count = sharedProviders().count
        info.text = count > 0
            ? "本次接收 \(count) 项照片或视频。逐项保存到持久化队列；iOS 可能为分享创建临时副本，NAS 验证后会清理暂存。"
            : "将照片和视频加入 FileMann 持久化队列；传输时不会主动删除相册原件。"
        batchProgress.isHidden = true
        batchProgress.progress = 0

        action.setTitle("添加到传输队列", for: .normal)
        action.addTarget(self, action: #selector(beginImport), for: .touchUpInside)

        cancel.setTitle("取消", for: .normal)
        cancel.addTarget(self, action: #selector(cancelImport), for: .touchUpInside)

        let controls = UIStackView(arrangedSubviews: [cancel, action, progress])
        controls.axis = .horizontal
        controls.distribution = .equalSpacing
        controls.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            title, info, batchProgress, controls
        ])
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
        if partialImport != nil {
            // We deliberately avoid silently closing on partial failure.
            // The user must acknowledge that only the reported subset
            // reached the durable App Group inbox.
            extensionContext?.completeRequest(
                returningItems: [], completionHandler: nil
            )
            return
        }

        isSubmitting = true
        action.isEnabled = false
        progress.startAnimating()
        batchProgress.isHidden = false
        batchProgress.progress = 0

        Task { @MainActor in
            do {
                let summary = try await importAttachments()
                progress.stopAnimating()
                batchProgress.progress = 1

                guard summary.imported > 0 else {
                    let first = summary.firstErrors.first
                        ?? "没有任何支持的图片或视频"
                    throw ShareError.allFailed(
                        "接收 \(summary.received) 项，成功 0 项，" +
                        "失败 \(summary.failed) 项，不支持 \(summary.unsupported) 项。" +
                        first
                    )
                }

                if summary.hasIssues {
                    // Never report success for 200 items if only some were
                    // staged. Already-staged media is durable and remains
                    // available to FileMann after this extension exits.
                    partialImport = summary
                    preferredContentSize = CGSize(width: 360, height: 360)
                    let detail = summary.firstErrors.prefix(2)
                        .joined(separator: "\n")
                    info.text =
                        "已暂存 \(summary.imported)/\(summary.received) 项；" +
                        "其中 \(summary.awaitingNames) 项待确认文件名；" +
                        "失败 \(summary.failed) 项、不支持 \(summary.unsupported) 项。" +
                        (detail.isEmpty ? "" : "\n" + detail) +
                        "\n已暂存内容不会因关闭面板丢失；" +
                        "请在相册重新选择剩余项目。"
                    action.setTitle(
                        "完成（保留已导入 \(summary.imported) 项）",
                        for: .normal
                    )
                    cancel.setTitle("关闭（保留暂存）", for: .normal)
                    action.isEnabled = true
                    isSubmitting = false
                    return
                }

                info.text = "已加入 \(summary.imported) 项到持久化队列，" +
                    "其中 \(summary.awaitingNames) 项待确认文件名。" +
                    "打开 FileMann 可根据相册序号和缩略图自定义名称，" +
                    "或选择使用临时占位文件名。"
                extensionContext?.completeRequest(
                    returningItems: [], completionHandler: nil
                )
            } catch {
                progress.stopAnimating()
                batchProgress.isHidden = true
                info.text = "未能完成导入：\(error.localizedDescription)"
                action.isEnabled = true
                isSubmitting = false
            }
        }
    }

    private enum ShareError: LocalizedError {
        case allFailed(String)
        case providerFailed

        var errorDescription: String? {
            switch self {
            case .allFailed(let message):
                return message
            case .providerFailed:
                return "分享来源没有返回可读取的媒体文件"
            }
        }
    }

    private func importAttachments() async throws -> ShareImportSummary {
        // Keep each successfully staged file instead of rolling back an
        // entire 200+ item batch because one asset lacks an original name.
        // A suspended/killed extension cannot guarantee completion, but
        // everything it has already staged can be imported by the main app.
        let inbox = try FileMannShareGroup.incomingDirectory()
        let providers = sharedProviders()
        var summary = ShareImportSummary(received: providers.count)

        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            let processed = index + 1
            info.text =
                "正在处理 \(processed)/\(providers.count) 项 · " +
                "已暂存 \(summary.imported) 项 · " +
                "失败 \(summary.failed + summary.unsupported) 项"
            batchProgress.progress =
                Float(index) / Float(max(1, providers.count))

            // Prefer the actual media representation, not a generic
            // converted image or an unsupported text/file attachment.
            let supported = provider.registeredTypeIdentifiers.filter {
                guard let kind = UTType($0) else { return false }
                return kind.conforms(to: .movie) ||
                    kind.conforms(to: .image)
            }
            let identifier = supported.first {
                $0 != UTType.image.identifier &&
                    $0 != UTType.movie.identifier
            } ?? supported.first
            guard let identifier else {
                summary.unsupported += 1
                continue
            }

            do {
                let staged = try await stageMedia(
                    provider,
                    typeIdentifier: identifier,
                    selectionIndex: processed,
                    inbox: inbox
                )
                summary.imported += 1
                if FileMannShareFileNaming.readMetadata(
                    for: staged
                )?.needsFilenameDecision == true {
                    summary.awaitingNames += 1
                }
            } catch {
                summary.failed += 1
                if summary.firstErrors.count < 3 {
                    summary.firstErrors.append(
                        "第 \(processed) 项：\(error.localizedDescription)"
                    )
                }
            }
            batchProgress.progress =
                Float(processed) / Float(max(1, providers.count))
        }
        return summary
    }

    /// NSItemProvider URLs may be invalid as soon as their callback returns.
    /// Resolve the real source filename and stage the file *inside* the
    /// callback. Photos providers that do not offer an in-place URL can
    /// still supply a temporary file representation.
    private func stageMedia(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        selectionIndex: Int,
        inbox: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in

            provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { url, _, _ in
                if let url {
                    do {
                        let stored = try FileMannShareFileNaming.stageForQueue(
                            sourceURL: url,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier,
                            selectionIndex: selectionIndex,
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
                        let stored = try FileMannShareFileNaming.stageForQueue(
                            sourceURL: temporaryURL,
                            suggestedName: provider.suggestedName,
                            typeIdentifier: typeIdentifier,
                            selectionIndex: selectionIndex,
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
