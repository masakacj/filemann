import QuickLookThumbnailing
import SwiftUI
import UIKit

struct DuplicateReviewView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var destructiveCandidate: DuplicateCandidate?
    @State private var isConfirmingKeepAllNAS = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("以下文件已经做过完整逐字节比较，内容完全一致；不是只按文件名或大小判断。选择“只保留手机”会删除 NAS 上对应副本。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if viewModel.selectableKeepNASDuplicateCount > 0 {
                        Button {
                            isConfirmingKeepAllNAS = true
                        } label: {
                            Label(
                                "全部保留 NAS（\(viewModel.selectableKeepNASDuplicateCount) 项）",
                                systemImage: "externaldrive.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("keep-nas-all-duplicates")
                    }
                }

                ForEach(viewModel.duplicateCandidates) { candidate in
                    if let task = viewModel.task(for: candidate) {
                        Section {
                            duplicateCard(candidate: candidate, task: task)
                        }
                    }
                }
            }
            .navigationTitle("重复文件")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "全部只保留 NAS 副本？",
                isPresented: $isConfirmingKeepAllNAS
            ) {
                Button("全部保留 NAS") {
                    viewModel.keepNASForAllPendingDuplicates()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(
                    "将 \(viewModel.selectableKeepNASDuplicateCount) 项尚未执行的重复文件统一设为“只保留 NAS”。" +
                    "不会删除 NAS 文件；开始归档并通过整批校验后才清理对应手机副本。已完成任务不受影响。"
                )
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.unresolvedDuplicateCount == 0 ? "完成" : "稍后处理") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "只保留手机副本？",
                isPresented: Binding(
                    get: { destructiveCandidate != nil },
                    set: { if !$0 { destructiveCandidate = nil } }
                ),
                presenting: destructiveCandidate
            ) { candidate in
                Button("删除 NAS 副本", role: .destructive) {
                    viewModel.setDuplicateDecision(candidate.id, decision: .keepPhone)
                    destructiveCandidate = nil
                }
                Button("取消", role: .cancel) {
                    destructiveCandidate = nil
                }
            } message: { candidate in
                Text("将删除 NAS 上的 \(candidate.remoteName)，手机文件保留。")
            }
        }
    }

    @ViewBuilder
    private func duplicateCard(candidate: DuplicateCandidate, task: ArchiveTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                FileThumbnailView(bookmark: task.bookmark)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    Text(ByteFormat.string(candidate.fileSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Label("内容逐字节一致", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)

                    if candidate.decision != .unresolved {
                        Text("已选：\(candidate.decision.title)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                copyColumn(
                    title: "手机",
                    icon: "iphone",
                    name: task.displayName,
                    path: task.sourceRelativePath
                )

                Divider()

                copyColumn(
                    title: "NAS",
                    icon: "externaldrive",
                    name: candidate.remoteName,
                    path: candidate.remotePath
                )
            }

            if task.state == .completed || task.state == .skipped {
                Label("该重复文件已处理，无法更改", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("只保留 NAS") {
                        viewModel.setDuplicateDecision(candidate.id, decision: .keepNAS)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("两边都保留") {
                        viewModel.setDuplicateDecision(candidate.id, decision: .keepBoth)
                    }
                    .buttonStyle(.bordered)

                    Button("只保留手机", role: .destructive) {
                        destructiveCandidate = candidate
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func copyColumn(title: String, icon: String, name: String, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.bold())
            Text(name)
                .font(.subheadline)
                .lineLimit(2)
            if let path, !path.isEmpty {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reusable preview of a staged photo/video, including unnamed Photos
/// shares that need identification by thumbnail rather than filename.
struct FileThumbnailView: View {
    let bookmark: Data
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task {
            image = await loadThumbnail()
        }
    }

    private func loadThumbnail() async -> UIImage? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 240),
            scale: 2,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }
}
