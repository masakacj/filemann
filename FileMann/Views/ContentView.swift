import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summary
                    .padding()

                sourceLocations

                controls
                    .padding(.horizontal)
                    .padding(.vertical, 10)

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
                        description: Text("可“添加手机位置”长期记忆一个文件夹，也可临时“选择文件”。")
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
                    if !viewModel.duplicateCandidates.isEmpty {
                        Button {
                            viewModel.isShowingDuplicateReview = true
                        } label: {
                            if viewModel.unresolvedDuplicateCount > 0 {
                                Label("\(viewModel.unresolvedDuplicateCount)", systemImage: "square.on.square")
                            } else {
                                Image(systemName: "square.on.square")
                            }
                        }
                        .accessibilityLabel("重复文件")
                    }

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
        .sheet(isPresented: $viewModel.isShowingFilePicker) {
            DocumentPicker { urls in
                viewModel.isShowingFilePicker = false
                viewModel.addDocuments(urls)
            }
        }
        .sheet(isPresented: $viewModel.isShowingFolderPicker) {
            FolderPicker { url in
                viewModel.isShowingFolderPicker = false
                viewModel.addSourceLocation(url)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingDuplicateReview) {
            DuplicateReviewView()
                .environmentObject(viewModel)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("总进度")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.completedCount)/\(viewModel.tasks.filter { $0.state != .skipped }.count)")
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

            if let verification = viewModel.lastVerification {
                HStack(spacing: 6) {
                    Image(systemName: verification.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    Text(
                        verification.passed
                        ? "双边校验通过：\(verification.verifiedCount) 个 · \(ByteFormat.string(verification.verifiedBytes))"
                        : "校验未通过：清单 \(verification.expectedCount) 个 / \(ByteFormat.string(verification.expectedBytes))；NAS \(verification.verifiedCount) 个 / \(ByteFormat.string(verification.verifiedBytes))"
                    )
                }
                .font(.caption)
                .foregroundStyle(verification.passed ? .green : .orange)
            }
        }
    }

    @ViewBuilder
    private var sourceLocations: some View {
        if !viewModel.sourceLocations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.sourceLocations) { location in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text(location.displayName)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                            }

                            Text("\(location.lastFileCount) 个 · \(ByteFormat.string(location.lastTotalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("重新扫描") {
                                    viewModel.scanLocation(location.id)
                                }
                                .buttonStyle(.borderless)

                                Button("移除") {
                                    viewModel.removeSourceLocation(location)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                            .font(.caption)
                        }
                        .frame(width: 210, alignment: .leading)
                        .padding(10)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    viewModel.isShowingFolderPicker = true
                } label: {
                    Label("添加手机位置", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanningLocation)

                Button {
                    viewModel.isShowingFilePicker = true
                } label: {
                    Label("选择文件", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

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
                    Label(
                        viewModel.unresolvedDuplicateCount > 0 ? "处理重复文件" : "开始归档",
                        systemImage: viewModel.unresolvedDuplicateCount > 0 ? "square.on.square" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.tasks.isEmpty || viewModel.isScanningLocation)
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayName)
                        .lineLimit(1)
                    if let relative = task.sourceRelativePath, relative != task.displayName {
                        Text(relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(task.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if task.state != .skipped {
                ProgressView(value: task.progress)

                HStack {
                    Text("\(ByteFormat.string(task.transferredBytes)) / \(ByteFormat.string(task.fileSize))")
                    Spacer()
                    Text("\(Int(task.progress * 100))%")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(task.state == .completed || task.state == .skipped ? .orange : .red)
            }

            if task.state == .completed && task.sourceDeleted {
                Label("NAS 已通过整批校验，手机源文件已删除", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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

    private var iconStyle: Color {
        switch task.state {
        case .completed: return .green
        case .skipped: return .orange
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
