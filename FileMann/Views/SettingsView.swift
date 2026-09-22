import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

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

                    TextField("归档目录（可留空）", text: $viewModel.settings.remoteDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("用户名", text: $viewModel.settings.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $viewModel.password)
                }

                Section {
                    Toggle("归档成功后删除手机源文件", isOn: $viewModel.settings.deleteAfterArchive)

                    Picker("断点块大小", selection: $viewModel.settings.chunkSizeMB) {
                        Text("4 MB").tag(4)
                        Text("8 MB").tag(8)
                        Text("16 MB").tag(16)
                        Text("32 MB").tag(32)
                    }
                } header: {
                    Text("归档")
                } footer: {
                    Text("文件会先写入 .filemann-partial；中断后根据 NAS 上的 partial 大小续传。最终文件大小校验成功后才删除源文件。")
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
                    Text("共享名是 SMB 的第一层 share，例如 \\NAS\\storage；子目录请填在“归档目录”。")
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
        }
    }
}
