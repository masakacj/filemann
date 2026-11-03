import SwiftUI

/// Persisted archive queue, independent from which media tab is open.
struct TransferQueueView: View {
    @EnvironmentObject private var model: ArchiveViewModel
    @State private var isShowingOriginalPicker = false
    @State private var isShowingClearConfirmation = false
    @State private var isShowingRename = false
    @State private var renamingTask: ArchiveTask?
    @State private var filenameDraft = ""
    @State private var showOnlyUnnamed = false

    private var outstandingCount: Int {
        model.tasks.filter { task in
            switch task.state {
            case .queued, .uploading, .paused, .failed, .missingSource:
                return true
            case .completed, .skipped:
                return false
            }
        }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("传输进度").font(.headline)
                            Spacer()
                            Text("\(model.completedCount) / \(model.tasks.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: model.overallProgress)
                        if model.isRunning {
                            let stagedCount = model.tasks.filter {
                                $0.state == .uploading
                            }.count
                            Label(
                                "已提交系统后台：\(stagedCount) 项；" +
                                "锁屏或切换 App 可以继续，手动上划强制关闭会中断",
                                systemImage: "iphone.gen3.radiowaves.left.and.right"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        HStack {
                            Label(
                                "\(outstandingCount) 项待处理",
                                systemImage: "tray.full"
                            )
                            Spacer()
                            Text(model.activeWebDAVEndpoint ?? "NAS")
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if model.isRunning && model.bytesPerSecond > 0 {
                            Label(
                                "当前总上传速度：\(ByteFormat.string(Int64(model.bytesPerSecond)))/s",
                                systemImage: "speedometer"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        if model.activeWebDAVEndpoint?.hasPrefix("远程") == true {
                            Label(
                                "正在使用远程 WebDAV；若 iPhone 与 NAS 在同一 Wi-Fi，" +
                                "配置可达的本地 WebDAV 地址通常能减少公网绕行。",
                                systemImage: "wifi.exclamationmark"
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 5)
                }

                Section {
                    Button {
                        isShowingOriginalPicker = true
                    } label: {
                        Label(
                            "从相册导入原格式（优先 HEIC）",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }

                    HStack {
                        Button {
                            model.start()
                        } label: {
                            Label(
                                model.isRunning ? "传输中" : "开始 / 继续",
                                systemImage: "play.fill"
                            )
                        }
                        .disabled(model.isRunning || outstandingCount == 0)
                        Spacer()
                        Button {
                            model.pause()
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                        .disabled(!model.isRunning)
                    }
                    if let message = model.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("任务列表（\(model.tasks.count)）") {
                    if model.unresolvedShareNamesCount > 0 {
                        HStack {
                            Label(
                                "\(model.unresolvedShareNamesCount) 项待确认文件名",
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
                    if model.tasks.isEmpty {
                        ContentUnavailableView(
                            "暂无归档任务",
                            systemImage: "arrow.up.doc",
                            description: Text(
                                "从本地媒体页面添加任务后，会在这里持久保存"
                            )
                        )
                    }
                    ForEach(
                        showOnlyUnnamed && model.unresolvedShareNamesCount > 0
                            ? model.tasks.filter {
                                $0.needsShareFilenameDecision
                            }
                            : model.tasks
                    ) { task in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(task.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Text(task.completionDescription)
                                    .font(.caption)
                                    .foregroundStyle(
                                        task.state == .failed
                                            ? .red : .secondary
                                    )
                            }
                            if task.needsShareFilenameDecision {
                                HStack(alignment: .top, spacing: 10) {
                                    FileThumbnailView(bookmark: task.bookmark)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(task.shareSelectionIndex.map {
                                            "相册第 \($0) 项，原文件名不可确定"
                                        } ?? "原文件名不可确定")
                                            .font(.caption.bold())
                                            .foregroundStyle(.orange)
                                        HStack {
                                            Button("自定义文件名") {
                                                renamingTask = task
                                                filenameDraft = ""
                                                isShowingRename = true
                                            }
                                            .buttonStyle(.bordered)
                                            Button("使用占位名") {
                                                model.approvePlaceholderName(for: task)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                        .font(.caption2)
                                    }
                                }
                            }
                            ProgressView(value: task.progress)
                            HStack {
                                Text(
                                    ByteCountFormatter.string(
                                        fromByteCount:
                                            task.transferredBytes,
                                        countStyle: .file
                                    )
                                )
                                Spacer()
                                if [.failed, .paused, .missingSource]
                                    .contains(task.state) {
                                    Button("重试") {
                                        model.retry(task)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let message = task.errorMessage {
                                Text(message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button("移除", role: .destructive) {
                                model.removeTask(task)
                            }
                        }
                    }
                }
            }
            .navigationTitle("传输队列")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清理已完成任务") {
                            model.clearCompleted()
                        }
                        if !model.tasks.isEmpty {
                            Button("清空全部任务", role: .destructive) {
                                isShowingClearConfirmation = true
                            }
                        }
                        Button("NAS / 配置中心设置") {
                            model.isShowingSettings = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingOriginalPicker) {
            OriginalPhotosPicker(
                onProgress: { processed, total in
                    model.statusMessage =
                        "正在从相册导入原格式 \(processed)/\(total)…"
                },
                onBatchStaged: {
                    model.importShareInbox()
                },
                onFinish: { imported, failed, errors in
                    model.importShareInbox()
                    let detail = errors.prefix(2).joined(separator: "\n")
                    model.statusMessage =
                        "原格式相册导入：成功 \(imported) 项，" +
                        "失败 \(failed) 项。" +
                        (detail.isEmpty ? "" : "\n" + detail)
                    isShowingOriginalPicker = false
                }
            )
        }
        .alert("自定义原文件名", isPresented: $isShowingRename) {
            TextField("完整文件名（含扩展名）", text: $filenameDraft)
            Button("保存") {
                if let task = renamingTask {
                    model.renameQueuedSharedMedia(task, to: filenameDraft)
                }
                renamingTask = nil
            }
            Button("取消", role: .cancel) {
                renamingTask = nil
            }
        } message: {
            Text("只有你确认后才会用此名称传输；原件不会被重命名")
        }
        .confirmationDialog(
            "确定清空全部传输任务？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部任务", role: .destructive) {
                model.clearAllTasks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会取消当前上传并删除 FileMann 暂存任务；不删除相册原件和 NAS 已有文件")
        }
    }
}
