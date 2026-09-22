import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDirectoryPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("SMB") {
                    TextField("服务器 IP / 主机名", text: $viewModel.settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("共享名（Share）", text: $viewModel.settings.share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("用户名", text: $viewModel.settings.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $viewModel.password)
                }

                Section("归档目录") {
                    HStack {
                        Image(systemName: "folder")
                        Text(viewModel.settings.normalizedDirectory.isEmpty ? "/" : "/\(viewModel.settings.normalizedDirectory)")
                            .font(.body.monospaced())
                            .lineLimit(2)
                    }

                    Button("浏览 NAS 并选择目录") {
                        isShowingDirectoryPicker = true
                    }

                    TextField("也可手动输入子目录", text: $viewModel.settings.remoteDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("整批校验通过后删除手机源文件", isOn: $viewModel.settings.deleteAfterArchive)

                    Picker("断点块大小", selection: $viewModel.settings.chunkSizeMB) {
                        Text("4 MB").tag(4)
                        Text("8 MB").tag(8)
                        Text("16 MB").tag(16)
                        Text("32 MB").tag(32)
                    }
                } header: {
                    Text("归档")
                } footer: {
                    Text("FileMann 会先完成全部传输，再逐项核对 NAS 文件数量和总字节数；只有整批校验通过才请求删除手机源文件。删除通过 iOS File Provider 执行，是否进入“最近删除/回收站”由具体文件提供者决定，FileMann 无法保证可恢复。")
                }

                Section {
                    Button("测试连接") {
                        viewModel.saveSettings()
                        viewModel.testConnection()
                    }

                    if let message = viewModel.connectionTestMessage {
                        Text(message)
                            .foregroundStyle(message == "连接成功" ? .green : .secondary)
                    }
                } footer: {
                    Text("共享名是 SMB 第一层 share，例如 \\NAS\\storage；归档目录是在该 share 内手动选择并记忆的子目录。")
                }
            }
            .navigationTitle("SMB 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.saveSettings()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isShowingDirectoryPicker) {
                SMBDirectoryPickerView()
                    .environmentObject(viewModel)
            }
        }
    }
}
