import Foundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingDirectoryPicker = false
    @State private var cacheSizeBytes: Int64 = 0
    @State private var cacheLimitMB =
        FileMannCachePolicy.limitMB
    @State private var isClearingCache = false
    @State private var cacheStatusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("传输方式") {
                    Picker(
                        "协议",
                        selection: $viewModel.settings.transport
                    ) {
                        ForEach(ArchiveTransport.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if viewModel.settings.transport == .webDAV {
                    webDAVConnections
                    webDAVArchiveOptions
                } else {
                    smbSection
                    smbArchiveOptions
                }

                connectionTestSection
                cacheSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(
                    placement: .confirmationAction
                ) {
                    Button("存储") {
                        viewModel.saveSettings()
                        dismiss()
                    }
                }
            }
            .sheet(
                isPresented: $isShowingDirectoryPicker
            ) {
                SMBDirectoryPickerView()
                    .environmentObject(viewModel)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await refreshCacheSize()
        }
    }

    private var webDAVConnections: some View {
        Section {
            NavigationLink {
                WebDAVEndpointEditor(
                    settings: $viewModel.settings,
                    password: $viewModel.webDAVPassword,
                    endpoint: .local
                )
            } label: {
                connectionRow(
                    title: viewModel.settings.webDAVLocalTitle,
                    host: viewModel.settings.webDAVLocalHost,
                    fallback: "未配置本地地址",
                    systemImage: "house.fill"
                )
            }

            NavigationLink {
                WebDAVEndpointEditor(
                    settings: $viewModel.settings,
                    password: $viewModel.webDAVPassword,
                    endpoint: .remote
                )
            } label: {
                connectionRow(
                    title: viewModel.settings.webDAVRemoteTitle,
                    host: viewModel.settings.webDAVRemoteHost,
                    fallback: "未配置远程地址",
                    systemImage: "globe"
                )
            }
        } header: {
            Text("WebDAV")
        } footer: {
            Text(
                "FileMann 始终优先尝试本地连接；本地不可达时自动切换远程连接。用户名和密码由两个地址共用。"
            )
        }
    }

    private var webDAVArchiveOptions: some View {
        Section {
            HStack {
                Image(systemName: "folder")
                Text(
                    viewModel.settings
                        .normalizedWebDAVDirectory
                        .isEmpty
                        ? "/"
                        : "/\(viewModel.settings.normalizedWebDAVDirectory)"
                )
                .font(.body.monospaced())
                .lineLimit(2)
            }

            Button("浏览并选择归档目录") {
                isShowingDirectoryPicker = true
            }
            .disabled(!viewModel.settings.isValid)

            TextField(
                "归档子目录",
                text: $viewModel.settings
                    .webDAVRemoteDirectory
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Toggle(
                "整批校验通过后删除手机源文件",
                isOn: $viewModel.settings.deleteAfterArchive
            )

            Toggle(
                "仅 Wi‑Fi",
                isOn: $viewModel.settings.webDAVWiFiOnly
            )

            LabeledContent("后台传输") {
                Label(
                    "iOS 系统托管",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        } header: {
            Text("归档")
        } footer: {
            Text(
                "归档目录相对于当前 WebDAV 根路径。上传完成后会再次核对 NAS 文件数量和字节数，通过后才按设置删除本地副本。"
            )
        }
    }

    private var smbSection: some View {
        Section("SMB 兼容模式") {
            TextField(
                "服务器 IP / 主机名",
                text: $viewModel.settings.host
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField(
                "共享名（Share）",
                text: $viewModel.settings.share
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField(
                "用户名",
                text: $viewModel.settings.username
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            SecureField(
                "密码",
                text: $viewModel.password
            )
        }
    }

    private var smbArchiveOptions: some View {
        Section("归档") {
            TextField(
                "归档子目录",
                text: $viewModel.settings.remoteDirectory
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Toggle(
                "整批校验通过后删除手机源文件",
                isOn: $viewModel.settings.deleteAfterArchive
            )

            Picker(
                "断点块大小",
                selection: $viewModel.settings.chunkSizeMB
            ) {
                Text("4 MB").tag(4)
                Text("8 MB").tag(8)
                Text("16 MB").tag(16)
                Text("32 MB").tag(32)
            }
        }
    }

    private var connectionTestSection: some View {
        Section {
            Button("测试连接") {
                viewModel.saveSettings()
                viewModel.testConnection()
            }

            if let message = viewModel.connectionTestMessage {
                Text(message)
                    .foregroundStyle(
                        message.hasPrefix("连接成功")
                            ? .green
                            : .secondary
                    )
            }
        } footer: {
            if viewModel.settings.transport == .webDAV {
                Text(
                    "本地和远程端口都支持自定义。远程连接建议使用证书有效的 HTTPS。"
                )
            }
        }
    }

    private var cacheSection: some View {
        Section {
            Picker(
                "最大缓存大小",
                selection: Binding(
                    get: { cacheLimitMB },
                    set: { updateCacheLimit($0) }
                )
            ) {
                ForEach(
                    FileMannCachePolicy.allowedLimitMB,
                    id: \.self
                ) { value in
                    Text(cacheLimitTitle(value))
                        .tag(value)
                }
            }

            LabeledContent("当前缓存") {
                if isClearingCache {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(byteCountString(cacheSizeBytes))
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                clearCache()
            } label: {
                Label(
                    "清理缓存",
                    systemImage: "trash"
                )
            }
            .disabled(isClearingCache)

            if let cacheStatusMessage {
                Text(cacheStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("缓存")
        } footer: {
            Text(
                "只管理可重新生成的 NAS 原图、缩略图和旧版网络缓存；不会删除本地媒体、Shortcut Inbox、归档任务或 NAS 文件。超过上限后会自动按最久未使用顺序清理。"
            )
        }
    }

    @MainActor
    private func updateCacheLimit(_ value: Int) {
        cacheLimitMB = value
        FileMannCachePolicy.limitMB = value
        cacheStatusMessage = nil

        Task {
            await FileMannCacheManager.shared
                .enforceLimit(force: true)
            await refreshCacheSize()
        }
    }

    @MainActor
    private func clearCache() {
        guard !isClearingCache else {
            return
        }

        isClearingCache = true
        cacheStatusMessage = nil
        RemoteThumbnailStore.shared.clearMemoryCache()

        Task {
            let freed = await FileMannCacheManager.shared
                .clearAllCache()
            cacheSizeBytes = await FileMannCacheManager.shared
                .currentSizeBytes()
            cacheStatusMessage =
                "已清理 " + byteCountString(freed)
            isClearingCache = false
        }
    }

    @MainActor
    private func refreshCacheSize() async {
        cacheSizeBytes = await FileMannCacheManager.shared
            .currentSizeBytes()
    }

    private func cacheLimitTitle(_ value: Int) -> String {
        value >= 1024
            ? "\(value / 1024) GB"
            : "\(value) MB"
    }

    private func byteCountString(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, value),
            countStyle: .file
        )
    }

    private func connectionRow(
        title: String,
        host: String,
        fallback: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(.yellow)

            VStack(
                alignment: .leading,
                spacing: 3
            ) {
                Text(
                    title.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        ? fallback
                        : title
                )

                Text(
                    host.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        ? fallback
                        : host
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private enum WebDAVEndpointKind {
    case local
    case remote

    var navigationTitle: String {
        switch self {
        case .local:
            return "本地 WebDAV"
        case .remote:
            return "远程 WebDAV"
        }
    }
}

private struct WebDAVEndpointEditor: View {
    @Binding var settings: SMBSettings
    @Binding var password: String

    let endpoint: WebDAVEndpointKind

    var body: some View {
        Form {
            Section {
                TextField(
                    "标题",
                    text: titleBinding
                )

                TextField(
                    "主机",
                    text: hostBinding
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                TextField(
                    "用户",
                    text: $settings.webDAVUsername
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                SecureField(
                    "密码",
                    text: $password
                )
            }

            Section("高级") {
                TextField(
                    "端口",
                    text: portBinding
                )
                .keyboardType(.numberPad)

                TextField(
                    "路径",
                    text: pathBinding
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Toggle(
                    "HTTPS",
                    isOn: httpsBinding
                )

                if httpsBinding.wrappedValue {
                    Toggle(
                        "兼容自签/无效证书",
                        isOn: invalidCertificateBinding
                    )
                }
            }

            Section {
                LabeledContent("实际地址") {
                    Text(previewURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(
                    endpoint == .local
                        ? "本地地址用于家中局域网，支持自定义端口。若 NAS 使用自签证书或证书与 IP 不匹配，可开启“兼容自签/无效证书”。"
                        : "远程地址用于外网访问，优先使用有效 HTTPS 证书。只有确认这是你自己的 NAS 时，才建议开启“兼容自签/无效证书”。"
                )
            }
        }
        .navigationTitle(endpoint.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalTitle
                    : settings.webDAVRemoteTitle
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalTitle = value
                } else {
                    settings.webDAVRemoteTitle = value
                }
            }
        )
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalHost
                    : settings.webDAVRemoteHost
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalHost = value
                } else {
                    settings.webDAVRemoteHost = value
                }
            }
        )
    }

    private var portBinding: Binding<String> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalPort
                    : settings.webDAVRemotePort
            },
            set: { value in
                let filtered = value.filter(\.isNumber)
                if endpoint == .local {
                    settings.webDAVLocalPort = filtered
                } else {
                    settings.webDAVRemotePort = filtered
                }
            }
        )
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalPath
                    : settings.webDAVRemotePath
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalPath = value
                } else {
                    settings.webDAVRemotePath = value
                }
            }
        )
    }

    private var httpsBinding: Binding<Bool> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalHTTPS
                    : settings.webDAVRemoteHTTPS
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalHTTPS = value
                } else {
                    settings.webDAVRemoteHTTPS = value
                }
            }
        )
    }

    private var invalidCertificateBinding: Binding<Bool> {
        Binding(
            get: {
                endpoint == .local
                    ? settings.webDAVLocalAllowInvalidCertificate
                    : settings.webDAVRemoteAllowInvalidCertificate
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalAllowInvalidCertificate = value
                } else {
                    settings.webDAVRemoteAllowInvalidCertificate = value
                }
            }
        )
    }

    private var previewURL: String {
        switch endpoint {
        case .local:
            return settings.normalizedWebDAVBaseURL
        case .remote:
            return settings.normalizedWebDAVRemoteBaseURL
        }
    }
}
