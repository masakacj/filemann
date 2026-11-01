import SwiftUI

/// Persisted archive queue, independent from which media tab is open.
struct TransferQueueView: View {
    @EnvironmentObject private var model: ArchiveViewModel

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
                    }
                    .padding(.vertical, 5)
                }

                Section {
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
                    if model.tasks.isEmpty {
                        ContentUnavailableView(
                            "暂无归档任务",
                            systemImage: "arrow.up.doc",
                            description: Text(
                                "从本地媒体页面添加任务后，会在这里持久保存"
                            )
                        )
                    }
                    ForEach(model.tasks) { task in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(task.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Text(task.state.title)
                                    .font(.caption)
                                    .foregroundStyle(
                                        task.state == .failed
                                            ? .red : .secondary
                                    )
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
                        Button("NAS / 配置中心设置") {
                            model.isShowingSettings = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}
