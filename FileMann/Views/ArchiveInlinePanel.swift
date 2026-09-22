import SwiftUI

struct ArchiveInlinePanel: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @AppStorage("filemann.archive.panel.expanded")
    private var isExpanded = true

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

                    ForEach(viewModel.tasks) { task in
                        ArchiveInlineTaskRow(task: task)
                            .environmentObject(viewModel)
                    }
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var activeTaskCount: Int {
        viewModel.tasks.filter { $0.state != .skipped }.count
    }
}

private struct ArchiveInlineTaskRow: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    let task: ArchiveTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)

                Text(task.displayName)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Text(task.state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Menu {
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

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
