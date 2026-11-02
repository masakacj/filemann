import SwiftUI

struct SMBDirectoryPickerView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""
    @State private var directories: [SMBDirectoryEntry] = []
    @State private var isLoading = false
    @State private var isCheckingWrite = false
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
                            Text("WebDAV：\(viewModel.activeWebDAVEndpoint ?? "正在选择可用地址")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                if !path.isEmpty {
                    Button {
                        path = ""
                        Task { await load() }
                    } label: {
                        Label("从 WebDAV 根目录重新选择", systemImage: "house")
                    }
                    Button {
                        path = parentPath(path)
                        Task { await load() }
                    } label: {
                        Label("上一级", systemImage: "arrow.up")
                    }
                }

                Section {
                    Text(
                        "这里显示的是当前 WebDAV 服务内的文件夹，不能照搬"
                        + " SMB 路径。选择前会测试临时文件的写入、"
                        + "重命名和删除权限；测试通过才保存。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = errorMessage
                            } label: {
                                Label("复制完整诊断", systemImage: "doc.on.doc")
                            }
                        }
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
                    Button {
                        verifyAndChoose()
                    } label: {
                        if isCheckingWrite {
                            ProgressView()
                        } else {
                            Text("验证写入并选择")
                        }
                    }
                    .disabled(isCheckingWrite || isLoading)
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

    private func verifyAndChoose() {
        guard !isCheckingWrite else { return }
        isCheckingWrite = true
        errorMessage = nil
        let selectedPath = path
        Task {
            defer { isCheckingWrite = false }
            do {
                try await viewModel.verifyWebDAVArchiveDirectory(
                    at: selectedPath
                )
                // Do not persist until the actual server proves the
                // destination supports PUT, MOVE and DELETE.
                viewModel.chooseRemoteDirectory(selectedPath)
                dismiss()
            } catch {
                errorMessage =
                    "此文件夹未通过 WebDAV 写入测试：\n" +
                    error.localizedDescription
            }
        }
    }

    private func parentPath(_ value: String) -> String {
        let parts = value.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }
}
