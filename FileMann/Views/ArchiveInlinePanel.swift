import SwiftUI
import UIKit

struct ArchiveInlinePanel: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @AppStorage("filemann.archive.panel.expanded")
    private var isExpanded = true
    @State private var isConfirmingClearAll = false
    @State private var showOnlyUnnamed = false

    var body: some View {
        if !viewModel.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                    Text("NAS 归档")
                        .font(.headline)

                    Spacer()

                    Text("\(viewModel.completedCount)/\(activeTaskCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                }

                ProgressView(value: viewModel.overallProgress)

                HStack {
                    Text("\(ByteFormat.string(viewModel.transferredBytes)) / \(ByteFormat.string(viewModel.totalBytes))")
                    Spacer()
                    if viewModel.isRunning, viewModel.bytesPerSecond > 0 {
                        Text("\(ByteFormat.string(Int64(viewModel.bytesPerSecond)))/s")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if viewModel.isRunning {
                        Button {
                            viewModel.pause()
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            viewModel.start()
                        } label: {
                            Label(
                                viewModel.unresolvedDuplicateCount > 0 ? "处理重复" : "继续归档",
                                systemImage: viewModel.unresolvedDuplicateCount > 0
                                    ? "square.on.square"
                                    : "play.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        viewModel.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.duplicateCandidates.isEmpty {
                        Button {
                            viewModel.isShowingDuplicateReview = true
                        } label: {
                            Label(
                                "\(viewModel.unresolvedDuplicateCount)",
                                systemImage: "square.on.square"
                            )
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if viewModel.completedCount > 0 {
                        Button("清理完成") {
                            viewModel.clearCompleted()
                        }
                        .font(.caption)
                    }
                    Button("清空全部") {
                        isConfirmingClearAll = true
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }

                if viewModel.tasks.contains(where: {
                    $0.state == .completed
                }) {
                    Button {
                        viewModel.recheckCompletedArchives()
                    } label: {
                        Label(
                            viewModel.isRecheckingArchives
                                ? "正在核验实际 NAS 路径…"
                                : "核验已完成文件 / 查看落盘位置",
                            systemImage: "checkmark.shield"
                        )
                    }
                    .font(.caption)
                    .disabled(viewModel.isRecheckingArchives || viewModel.isRunning)
                }

                if let verification = viewModel.lastVerification {
                    Label(
                        verification.passed
                            ? "校验通过：\(verification.verifiedCount) 个 · \(ByteFormat.string(verification.verifiedBytes))"
                            : "校验未通过：NAS \(verification.verifiedCount)/\(verification.expectedCount)",
                        systemImage: verification.passed
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(verification.passed ? .green : .orange)
                }

                if let message = viewModel.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isExpanded {
                    Divider()
                    if viewModel.unresolvedShareNamesCount > 0 {
                        HStack(spacing: 8) {
                            Label(
                                "\(viewModel.unresolvedShareNamesCount) 项待确认文件名",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Spacer()
                            Button(
                                showOnlyUnnamed ? "显示全部" : "只看待命名"
                            ) {
                                showOnlyUnnamed.toggle()
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption)
                    }

                    ForEach(showOnlyUnnamed && viewModel.unresolvedShareNamesCount > 0
                        ? viewModel.tasks.filter {
                            $0.needsShareFilenameDecision
                        }
                        : viewModel.tasks) { task in
                        ArchiveInlineTaskRow(task: task)
                            .environmentObject(viewModel)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .confirmationDialog(
                "清空所有传输任务？",
                isPresented: $isConfirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("清空全部任务", role: .destructive) {
                    viewModel.clearAllTasks()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    "将取消当前上传，清除全部队列记录和 FileMann 暂存媒体。" +
                    "不会删除相册原件或 NAS 已有文件。"
                )
            }
        }
    }

    private var activeTaskCount: Int {
        viewModel.tasks.filter { $0.state != .skipped }.count
    }
}

private struct ArchiveInlineTaskRow: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    let task: ArchiveTask
    @State private var isRenaming = false
    @State private var filenameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)

                Text(task.displayName)
                    .font(.subheadline)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer()

                Text(task.completionDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Menu {
                    if task.isShareStaging == true &&
                        [.queued, .failed, .missingSource]
                            .contains(task.state) {
                        Button {
                            filenameDraft = task.displayName
                            isRenaming = true
                        } label: {
                            Label("修改上传文件名", systemImage: "pencil")
                        }
                    }
                    if task.state == .failed || task.state == .missingSource {
                        Button {
                            viewModel.retry(task)
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                    }

                    Button(role: .destructive) {
                        viewModel.removeTask(task)
                    } label: {
                        Label("移除任务", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
            }

            if task.state != .skipped {
                ProgressView(value: task.progress)
                    .controlSize(.small)

                HStack {
                    Text(ByteFormat.string(task.transferredBytes))
                    Spacer()
                    Text("\(Int(task.progress * 100))%")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if task.needsShareFilenameDecision {
                HStack(alignment: .top, spacing: 8) {
                    FileThumbnailView(bookmark: task.bookmark)
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            task.shareSelectionIndex.map {
                                "相册第 \($0) 项 · 文件名未知"
                            } ?? "文件名未知 · 待处理",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        Text("请依据缩略图选择名称后再传输")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button("自定义文件名") {
                                filenameDraft = task.displayName
                                isRenaming = true
                            }
                            Button("使用占位名") {
                                viewModel.approvePlaceholderName(for: task)
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }
                }
            }

            if task.remoteFileName != task.displayName {
                Text("NAS 最终文件名：\(task.remoteFileName)")
                    .font(.caption2)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            if let url = task.remoteAbsoluteURL {
                HStack(alignment: .top, spacing: 5) {
                    Text("NAS：\(url)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制 NAS 实际文件地址")
                }
                .foregroundStyle(.secondary)
            }
            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .alert("修改归档文件名", isPresented: $isRenaming) {
            TextField("文件名", text: $filenameDraft)
            Button("保存") {
                viewModel.renameQueuedSharedMedia(
                    task, to: filenameDraft
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅修改未来 NAS 文件名，不会重命名或删除相册原件")
        }
    }

    private var icon: String {
        switch task.state {
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed, .missingSource: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock"
        }
    }

    private var iconColor: Color {
        switch task.state {
        case .completed: return .green
        case .skipped: return .orange
        case .failed, .missingSource: return .red
        case .uploading: return .blue
        case .paused, .queued: return .secondary
        }
    }
}
