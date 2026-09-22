import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summary
                    .padding()

                controls
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                if let message = viewModel.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if viewModel.tasks.isEmpty {
                    ContentUnavailableView(
                        "还没有归档任务",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("点“选择文件”，可直接从 Documents 等文件提供者多选文件。")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.tasks) { task in
                            ArchiveTaskRow(task: task)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        viewModel.removeTask(task)
                                    } label: {
                                        Label("移除", systemImage: "trash")
                                    }

                                    if task.state == .failed || task.state == .missingSource {
                                        Button {
                                            viewModel.retry(task)
                                        } label: {
                                            Label("重试", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.blue)
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("FileMann")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.completedCount > 0 {
                        Button("清理完成") {
                            viewModel.clearCompleted()
                        }
                    }

                    Button {
                        viewModel.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("SMB 设置")
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingPicker) {
            DocumentPicker { urls in
                viewModel.isShowingPicker = false
                viewModel.addDocuments(urls)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView()
                .environmentObject(viewModel)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("总进度")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.completedCount)/\(viewModel.tasks.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.isShowingPicker = true
            } label: {
                Label("选择文件", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if viewModel.isRunning {
                Button {
                    viewModel.pause()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    viewModel.start()
                } label: {
                    Label("开始归档", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.tasks.isEmpty)
            }
        }
    }
}

private struct ArchiveTaskRow: View {
    let task: ArchiveTask

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconStyle)

                Text(task.displayName)
                    .lineLimit(1)

                Spacer()

                Text(task.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: task.progress)

            HStack {
                Text("\(ByteFormat.string(task.transferredBytes)) / \(ByteFormat.string(task.fileSize))")
                Spacer()
                Text("\(Int(task.progress * 100))%")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(task.state == .completed ? .orange : .red)
            }

            if task.state == .completed && task.sourceDeleted {
                Label("NAS 已校验，手机源文件已删除", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch task.state {
        case .completed: return "checkmark.circle.fill"
        case .failed, .missingSource: return "exclamationmark.triangle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .queued: return "clock"
        }
    }

    private var iconStyle: Color {
        switch task.state {
        case .completed: return .green
        case .failed, .missingSource: return .red
        case .uploading: return .blue
        case .paused, .queued: return .secondary
        }
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
