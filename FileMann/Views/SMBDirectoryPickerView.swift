import SwiftUI

struct SMBDirectoryPickerView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var directories: [SMBDirectoryEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive.connected.to.line.below")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(path.isEmpty ? "/" : "/\(path)")
                                .font(.body.monospaced())
                            Text(
                                viewModel.settings.transport == .webDAV
                                    ? "WebDAV: \(viewModel.settings.normalizedWebDAVBaseURL)"
                                    : "Share: \(viewModel.settings.normalizedShare)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                if !path.isEmpty {
                    Button {
                        path = parentPath(path)
                        Task { await load() }
                    } label: {
                        Label("上一级", systemImage: "arrow.up")
                    }
                }

                Section("文件夹") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("读取目录…")
                        }
                    } else if directories.isEmpty {
                        Text("当前目录没有子文件夹")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(directories) { directory in
                            Button {
                                path = directory.path
                                Task { await load() }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(directory.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("选择 NAS 归档目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选择当前目录") {
                        viewModel.chooseRemoteDirectory(path)
                        dismiss()
                    }
                }
            }
            .task {
                path = viewModel.settings.activeRemoteDirectory
                await load()
            }
        }
    }

    private func load() async {
        guard viewModel.settings.isValid else {
            errorMessage = viewModel.settings.transport == .webDAV
                ? "请先填写 WebDAV 地址"
                : "请先填写服务器和共享名"
            directories = []
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            directories = try await viewModel.loadRemoteDirectories(at: path)
        } catch {
            directories = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func parentPath(_ value: String) -> String {
        let parts = value.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }
}
