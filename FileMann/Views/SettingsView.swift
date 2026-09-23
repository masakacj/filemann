import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDirectoryPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("传输方式") {
                    Picker("协议", selection: $viewModel.settings.transport) {
                        ForEach(ArchiveTransport.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if viewModel.settings.transport == .webDAV {
                    webDAVSection
                } else {
                    smbSection
                }

                archiveDirectorySection

                Section {
                    Toggle(
                        "整批校验通过后删除手机源文件",
                        isOn: $viewModel.settings.deleteAfterArchive
                    )

                    if viewModel.settings.transport == .webDAV {
                        Toggle(
                            "仅 Wi‑Fi",
                            isOn: $viewModel.settings.webDAVWiFiOnly
                        )

                        LabeledContent("后台传输") {
                            Label("iOS 系统托管", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        Picker("断点块大小", selection: $viewModel.settings.chunkSizeMB) {
                            Text("4 MB").tag(4)
                            Text("8 MB").tag(8)
                            Text("16 MB").tag(16)
                            Text("32 MB").tag(32)
                        }
                    }
                } header: {
                    Text("归档")
                } footer: {
                    if viewModel.settings.transport == .webDAV {
                        Text("WebDAV 上传使用 iOS Background URLSession。切到其他 App 或锁屏后，系统可继续上传；上传完成后 FileMann 再核对 NAS 文件数量和总字节数，通过后才按设置删除本地副本。")
                    } else {
                        Text("SMB 为兼容模式。FileMann 会先完成全部传输，再逐项核对 NAS 文件数量和总字节数；只有整批校验通过才请求删除手机源文件。")
                    }
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
                    if viewModel.settings.transport == .webDAV {
                        Text("QNAP 可使用 WebDAV。例如 http://NAS_IP:5000/共享名 或配置可信证书后的 https://NAS:5001/共享名。HTTP 仅建议在可信局域网使用。")
                    } else {
                        Text("共享名是 SMB 第一层 share，例如 \\NAS\\storage。")
                    }
                }
            }
            .navigationTitle("归档设置")
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

    private var webDAVSection: some View {
        Section("QNAP WebDAV") {
            TextField(
                "例如 http://192.168.1.10:5000/Archive",
                text: $viewModel.settings.webDAVBaseURL
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)

            TextField("用户名", text: $viewModel.settings.webDAVUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("密码", text: $viewModel.webDAVPassword)
        }
    }

    private var smbSection: some View {
        Section("SMB 兼容模式") {
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
    }

    private var archiveDirectorySection: some View {
        Section("归档子目录") {
            HStack {
                Image(systemName: "folder")
                Text(
                    viewModel.settings.activeRemoteDirectory.isEmpty
                        ? "/"
                        : "/\(viewModel.settings.activeRemoteDirectory)"
                )
                .font(.body.monospaced())
                .lineLimit(2)
            }

            Button("浏览并选择目录") {
                isShowingDirectoryPicker = true
            }
            .disabled(!viewModel.settings.isValid)

            if viewModel.settings.transport == .webDAV {
                TextField(
                    "也可手动输入子目录",
                    text: $viewModel.settings.webDAVRemoteDirectory
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
                TextField(
                    "也可手动输入子目录",
                    text: $viewModel.settings.remoteDirectory
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }
}
