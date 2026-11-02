import Foundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ArchiveViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingDirectoryPicker = false
    @State private var cacheLimitMB =
        FileMannCachePolicy.limitMB
    @State private var isClearingCache = false
    @State private var cacheStatusMessage: String?
    @State private var storageSnapshot =
        FileMannStorageSnapshot()
    @State private var isRefreshingStorage = false
    @State private var isClearingLocalMedia = false
    @State private var isClearingInbox = false
    @State private var showClearLocalMediaConfirmation = false
    @State private var showClearInboxConfirmation = false
    @State private var storageStatusMessage: String?
    @State private var isClearingSystemCache = false
    @State private var isClearingLegacyGroup = false
    @State private var showClearSystemCacheConfirmation = false
    @State private var showClearLegacyGroupConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(
                        "固定密码", text: $viewModel.configCenterPassword
                    )
                    .textContentType(.password)
                    Button {
                        viewModel.syncConfigCenter()
                    } label: {
                        HStack {
                            Text("读取并应用配置")
                            if viewModel.isConfigCenterSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isConfigCenterSyncing)
                    if let status = viewModel.configCenterStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("统一配置中心")
                } footer: {
                    Text("从 config.781751.xyz 读取 filemann 专属 NAS 配置，固定密码仅存本机 Keychain。离线时保留上次成功配置。")
                }

                Section("唯一传输协议") {
                    LabeledContent("协议", value: "WebDAV")
                    Text(
                        "家中优先连接局域网 NAS；外出仅使用可信 HTTPS 地址。"
                        + " 不开放 SMB 445 端口到互联网。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                webDAVConnections
                webDAVArchiveOptions

                connectionTestSection

                Section {
                    LabeledContent("App Group") {
                        if FileMannShareGroup.sharedContainer() != nil {
                            Label("共享容器可用", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("签名未授权", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("在 iOS 相册选择照片或视频 → 分享 → 传送到 FileMann。若首次未显示，可在分享列表的“更多”中开启。导入任务时不会永久保留另一份原文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("相册原生分享")
                }

                storageSection
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
            await refreshStorage()
        }
        .confirmationDialog(
            "删除 FileMann 本地媒体？",
            isPresented: $showClearLocalMediaConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "删除 \(byteCountString(storageSnapshot.localMediaBytes))",
                role: .destructive
            ) {
                clearLocalMedia()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "只删除 FileMann 私有媒体库中的图片/视频及其编辑元数据。不会删除 NAS 文件，也不会删除已映射的外部文件夹内容。iOS“存储空间”中的数字可能需要几分钟才会刷新。"
            )
        }
        .confirmationDialog(
            "清空 Shortcut Inbox？",
            isPresented: $showClearInboxConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "删除 \(byteCountString(storageSnapshot.shortcutInboxBytes))",
                role: .destructive
            ) {
                clearShortcutInbox()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "只删除“我的 iPhone / FileMann / Shortcut Inbox”中仍残留的文件。"
            )
        }
        .confirmationDialog(
            "清理系统 / 后台缓存？",
            isPresented: $showClearSystemCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "清理 \(byteCountString(storageSnapshot.systemCacheBytes))",
                role: .destructive
            ) {
                clearSystemCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "会清理 FileMann 沙盒 Library/Caches 中的可重建数据，包括可能由后台 URLSession 遗留的数据。存在未完成归档任务时不会允许执行。"
            )
        }
        .confirmationDialog(
            "清理旧版 App Group 媒体？",
            isPresented: $showClearLegacyGroupConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "删除 \(byteCountString(storageSnapshot.legacyAppGroupMediaBytes))",
                role: .destructive
            ) {
                clearLegacyGroup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "旧版 FileMann 曾把原始媒体保存在 group.com.masakacj.filemann/Media。这个操作只在当前签名仍有该 App Group 权限时可用，并会永久删除旧共享容器里的媒体。"
            )
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
                "优先局域网 WebDAV；本地不可达时尝试远程 HTTPS。外网必须有有效证书，不允许通过 HTTP 或忽略证书错误连接。"
            )
        }
    }

    private var webDAVArchiveOptions: some View {
        Section {
            HStack {
                Image(systemName: "folder")
                Text(
                    viewModel.settings.normalizedWebDAVDirectory.isEmpty
                        ? (viewModel.settings.hasWebDAVArchiveDirectory
                            ? "（WebDAV 共享根）"
                            : "/（NAS 根目录不可直接上传）")
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
                "如 WebDAV URL 已包含共享根（如 /Public），归档子目录可以留空。若只是 NAS 根目录 /，必须选可写共享目录。上传前执行临时文件 PUT/MOVE/DELETE 权限验证。"
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
            Button("测试连接与写入权限") {
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
            Text(
                "实际上传前会先验证 PUT / MOVE / DELETE 权限。"
                + " 目录可读取不代表可写；若发生 HTTP 403，将显示失败操作与路径。"
            )
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("FileMann 本地媒体") {
                Text(
                    byteCountString(
                        storageSnapshot.localMediaBytes
                    )
                )
                .foregroundStyle(
                    storageSnapshot.localMediaBytes > 0
                        ? .primary
                        : .secondary
                )
            }

            LabeledContent("Shortcut Inbox") {
                Text(
                    byteCountString(
                        storageSnapshot.shortcutInboxBytes
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("相册分享临时暂存") {
                Text(
                    byteCountString(
                        storageSnapshot.shareStagingBytes
                    )
                )
                .foregroundStyle(
                    storageSnapshot.shareStagingBytes > 0
                        ? .orange : .secondary
                )
            }

            LabeledContent("NAS 缓存") {
                Text(
                    byteCountString(
                        storageSnapshot.cacheBytes
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("元数据 / 临时文件") {
                Text(
                    byteCountString(
                        storageSnapshot.otherBytes
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("可管理合计") {
                if isRefreshingStorage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(
                        byteCountString(
                            storageSnapshot.managedBytes
                        )
                    )
                    .fontWeight(.semibold)
                }
            }

            LabeledContent("当前 App 沙盒总计") {
                Text(
                    byteCountString(
                        storageSnapshot.sandboxBytes
                    )
                )
                .fontWeight(.semibold)
            }

            LabeledContent("未归类沙盒") {
                Text(
                    byteCountString(
                        storageSnapshot
                            .unclassifiedSandboxBytes
                    )
                )
                .foregroundStyle(
                    storageSnapshot
                        .unclassifiedSandboxBytes >
                        100 * 1024 * 1024
                        ? .orange
                        : .secondary
                )
            }

            LabeledContent("Documents 总计") {
                Text(
                    byteCountString(
                        storageSnapshot.documentsBytes
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("Library/Caches 总计") {
                Text(
                    byteCountString(
                        storageSnapshot.totalCachesBytes
                    )
                )
                .foregroundStyle(
                    storageSnapshot.systemCacheBytes >
                        100 * 1024 * 1024
                        ? .orange
                        : .secondary
                )
            }

            LabeledContent("旧版 App Group") {
                if storageSnapshot
                    .legacyAppGroupAvailable {
                    Text(
                        byteCountString(
                            storageSnapshot
                                .legacyAppGroupBytes
                        )
                    )
                    .foregroundStyle(
                        storageSnapshot
                            .legacyAppGroupBytes > 0
                            ? .orange
                            : .secondary
                    )
                } else {
                    Text("当前签名无权限")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                refreshStorageTask()
            } label: {
                Label(
                    "重新计算占用",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshingStorage)

            Picker(
                "最大 NAS 缓存",
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

            Button {
                clearCache()
            } label: {
                Label(
                    "清理 NAS 缓存",
                    systemImage: "trash"
                )
            }
            .disabled(isClearingCache)

            if storageSnapshot.systemCacheBytes >
                1024 * 1024 {
                Button(role: .destructive) {
                    showClearSystemCacheConfirmation =
                        true
                } label: {
                    Label(
                        "清理系统 / 后台缓存",
                        systemImage:
                            "externaldrive.badge.minus"
                    )
                }
                .disabled(
                    isClearingSystemCache ||
                    hasPendingArchiveWork
                )
            }

            if storageSnapshot
                .legacyAppGroupAvailable &&
               storageSnapshot
                .legacyAppGroupMediaBytes > 0 {
                Button(role: .destructive) {
                    showClearLegacyGroupConfirmation =
                        true
                } label: {
                    Label(
                        "清理旧版 App Group 媒体",
                        systemImage: "archivebox"
                    )
                }
                .disabled(isClearingLegacyGroup)
            }

            if storageSnapshot.localMediaBytes > 0 {
                Button(role: .destructive) {
                    showClearLocalMediaConfirmation = true
                } label: {
                    Label(
                        "删除 FileMann 本地媒体",
                        systemImage:
                            "externaldrive.badge.xmark"
                    )
                }
                .disabled(
                    isClearingLocalMedia ||
                    hasPendingArchiveWork
                )
            }

            if storageSnapshot.shortcutInboxBytes > 0 {
                Button(role: .destructive) {
                    showClearInboxConfirmation = true
                } label: {
                    Label(
                        "清空 Shortcut Inbox",
                        systemImage:
                            "tray.and.arrow.down.fill"
                    )
                }
                .disabled(isClearingInbox)
            }

            if hasPendingArchiveWork &&
               storageSnapshot.localMediaBytes > 0 {
                Text(
                    "存在未完成的归档任务。为避免删除仍待上传的源文件，暂时禁用“删除 FileMann 本地媒体”。"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !storageSnapshot
                .legacyAppGroupAvailable {
                Text(
                    "历史版本曾使用 App Group“group.com.masakacj.filemann”存储媒体。若 iPhone“存储空间”明显大于“当前 App 沙盒总计”，差额很可能来自当前签名无权访问的旧共享容器。"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let cacheStatusMessage {
                Text(cacheStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let storageStatusMessage {
                Text(storageStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("存储占用")
        } footer: {
            Text(
                "“当前 App 沙盒总计”会扫描 Documents、Library 与 tmp；“未归类沙盒”可发现旧路径或系统数据。早期 FileMann 还使用过 App Group 共享容器，它不属于当前 App 沙盒，且只有带对应 entitlement 的签名才能访问。"
            )
        }
    }

    private var hasPendingArchiveWork: Bool {
        viewModel.tasks.contains { task in
            switch task.state {
            case .queued,
                 .uploading,
                 .paused,
                 .failed:
                return true
            case .completed,
                 .skipped,
                 .missingSource:
                return false
            }
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
            await refreshStorage()
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
            cacheStatusMessage =
                "已清理 NAS 缓存 " +
                byteCountString(freed)
            isClearingCache = false
            await refreshStorage()
        }
    }

    @MainActor
    private func clearLocalMedia() {
        guard !isClearingLocalMedia,
              !hasPendingArchiveWork else {
            return
        }

        isClearingLocalMedia = true
        storageStatusMessage = nil

        Task {
            let freed =
                await FileMannStorageManager.shared
                    .clearLocalMedia()
            storageStatusMessage =
                "已删除 FileMann 本地媒体 " +
                byteCountString(freed) +
                "。iOS 存储统计可能稍后才更新。"
            isClearingLocalMedia = false
            await refreshStorage()
        }
    }

    @MainActor
    private func clearShortcutInbox() {
        guard !isClearingInbox else {
            return
        }

        isClearingInbox = true
        storageStatusMessage = nil

        Task {
            let freed =
                await FileMannStorageManager.shared
                    .clearShortcutInbox()
            storageStatusMessage =
                "已清理 Shortcut Inbox " +
                byteCountString(freed)
            isClearingInbox = false
            await refreshStorage()
        }
    }

    @MainActor
    private func clearSystemCache() {
        guard !isClearingSystemCache,
              !hasPendingArchiveWork else {
            return
        }

        isClearingSystemCache = true
        storageStatusMessage = nil
        RemoteThumbnailStore.shared.clearMemoryCache()

        Task {
            let freed =
                await FileMannStorageManager.shared
                    .clearSystemCaches()
            storageStatusMessage =
                "已清理系统 / 后台缓存 " +
                byteCountString(freed)
            isClearingSystemCache = false
            await refreshStorage()
        }
    }

    @MainActor
    private func clearLegacyGroup() {
        guard !isClearingLegacyGroup else {
            return
        }

        isClearingLegacyGroup = true
        storageStatusMessage = nil

        Task {
            let freed =
                await FileMannStorageManager.shared
                    .clearLegacyAppGroupMedia()
            storageStatusMessage =
                "已清理旧版 App Group 媒体 " +
                byteCountString(freed) +
                "。iOS 存储统计可能稍后更新。"
            isClearingLegacyGroup = false
            await refreshStorage()
        }
    }

    @MainActor
    private func refreshStorageTask() {
        Task {
            await refreshStorage()
        }
    }

    @MainActor
    private func refreshStorage() async {
        guard !isRefreshingStorage else {
            return
        }

        isRefreshingStorage = true
        storageSnapshot =
            await FileMannStorageManager.shared
                .snapshot()
        isRefreshingStorage = false
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

    @State private var inspectedCertificate: WebDAVCertificateInspection?
    @State private var certificateStatus: String?
    @State private var certificateLoading = false
    @State private var verifiedFingerprint = ""
    @State private var pinnedFingerprint: String?
    @State private var confirmCertificatePin = false
    @State private var confirmRemoteTLSCompatibility = false

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

                if endpoint == .local {
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
                } else {
                    LabeledContent("远程连接", value: "仅 HTTPS")
                    Toggle(
                        "兼容 NAS 自签/无效证书",
                        isOn: invalidCertificateBinding
                    )
                    Text(
                        "仅在你信任这个 NAS 地址时开启。允许此地址在证书过期、"
                        + "自签或域名不匹配时连接；不会允许其他服务器。"
                        + " 不需要复制 SHA-256 指纹。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        ? "本地 WebDAV HTTP 仅限私有局域网地址（例如 192.168.x.x），也可启用 HTTPS。"
                        : "远程仍使用 HTTPS；如果 nPlayer 可以连接但 FileMann 提示证书错误，可在高级设置中单独开启本 NAS 证书兼容模式。"
                )
            }

            if endpoint == .remote {
                remoteCertificateSection
            }
        }
        .navigationTitle(endpoint.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear { refreshCertificatePin() }
        .onChange(of: previewURL) { _, _ in
            inspectedCertificate = nil
            certificateStatus = nil
            verifiedFingerprint = ""
            refreshCertificatePin()
        }
        .confirmationDialog(
            "放宽该 NAS 的 HTTPS 证书校验？",
            isPresented: $confirmRemoteTLSCompatibility,
            titleVisibility: .visible
        ) {
            Button("仅对此 NAS 开启兼容模式") {
                settings.enableRemoteCertificateCompatibility()
                certificateStatus = "已开启当前 NAS 证书兼容模式；请返回设置并保存。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                "仍会通过 HTTPS 传输，但不能确认服务器证书的真实身份，"
                + "可能面临中间人攻击。仅在可信 NAS 环境使用，"
                + "修改服务器地址时将自动关闭。"
            )
        }
        .alert("信任这个 NAS 服务器证书？", isPresented: $confirmCertificatePin) {
            Button("取消", role: .cancel) {}
            Button("确认已从 NAS 核对指纹") {
                saveCertificatePin()
            }
        } message: {
            Text(
                "仅适用于当前 HTTPS 主机及端口。必须通过可信的 NAS 管理界面或其他独立渠道核对 SHA-256 指纹。证书变化后将重新拒绝连接。"
            )
        }
    }

    private var remoteCertificateSection: some View {
        Section {
            Button {
                inspectRemoteCertificate()
            } label: {
                HStack {
                    Text("检查服务器证书")
                    if certificateLoading {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(certificateLoading)

            if let certificateStatus {
                Text(certificateStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let inspectedCertificate {
                LabeledContent("服务器") {
                    Text("\(inspectedCertificate.host):\(inspectedCertificate.port)")
                        .font(.caption.monospaced())
                }
                LabeledContent("证书主体") {
                    Text(inspectedCertificate.subject)
                        .font(.caption)
                }
                LabeledContent("SHA-256 指纹") {
                    Text(inspectedCertificate.formattedFingerprint)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                if inspectedCertificate.systemTrusted {
                    Label("iOS 已信任该证书", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                } else {
                    Label("iOS 未信任：\(inspectedCertificate.reason)",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !inspectedCertificate.systemTrusted &&
                    pinnedFingerprint != inspectedCertificate.fingerprint {
                    Text(
                        "须与 NAS 管理端显示的 SHA-256 指纹独立核对后才能信任。"
                        + " 不要仅从此页面复制指纹并确认。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    TextField(
                        "输入从 NAS 核对的 SHA-256 指纹",
                        text: $verifiedFingerprint
                    )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                    Button("固定信任已核对的证书") {
                        confirmCertificatePin = true
                    }
                    .disabled(
                        WebDAVCertificateTrust.normalizeFingerprint(
                            verifiedFingerprint
                        ) != inspectedCertificate.fingerprint
                    )
                }
            }

            if let pinnedFingerprint {
                Label(
                    "已固定证书：\(pinnedFingerprint.prefix(16))…",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                Button(role: .destructive) {
                    forgetCertificatePin()
                } label: {
                    Text("撤销证书信任")
                }
            }
        } header: {
            Text("远程 HTTPS 证书")
        } footer: {
            Text(
                "只对当前地址和端口保存证书指纹，不会跳过其他服务器的验证。"
                + " 更推荐直接为 NAS 安装正确域名、有效期与证书链的 HTTPS 证书。"
            )
        }
    }

    private var remoteEndpoint: (host: String, port: Int)? {
        guard let url = URL(string: previewURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return (host, url.port ?? 443)
    }

    private func refreshCertificatePin() {
        guard let endpoint = remoteEndpoint else {
            pinnedFingerprint = nil
            return
        }
        pinnedFingerprint = WebDAVCertificateTrust.pinnedFingerprint(
            host: endpoint.host, port: endpoint.port
        )
    }

    private func inspectRemoteCertificate() {
        certificateLoading = true
        certificateStatus = "正在读取 TLS 证书（不发送 NAS 用户名和密码）…"
        inspectedCertificate = nil
        verifiedFingerprint = ""
        let currentURL = previewURL
        Task {
            defer { certificateLoading = false }
            do {
                let result = try await WebDAVCertificateInspector.inspect(
                    urlString: currentURL
                )
                guard currentURL == previewURL else { return }
                inspectedCertificate = result
                certificateStatus = result.systemTrusted
                    ? "证书链和主机名验证通过。"
                    : "证书未通过 iOS 系统验证，请与 NAS 端核对指纹。"
            } catch {
                certificateStatus = "无法读取服务器证书：" +
                    error.localizedDescription
            }
        }
    }

    private func saveCertificatePin() {
        guard let target = remoteEndpoint,
              let inspectedCertificate,
              inspectedCertificate.host.caseInsensitiveCompare(
                  target.host
              ) == .orderedSame,
              inspectedCertificate.port == target.port,
              !inspectedCertificate.systemTrusted,
              WebDAVCertificateTrust.normalizeFingerprint(
                  verifiedFingerprint
              ) == inspectedCertificate.fingerprint else {
            certificateStatus = "证书指纹或服务器地址已变化，请重新检查"
            return
        }

        do {
            try WebDAVCertificateTrust.save(
                inspectedCertificate.fingerprint,
                host: target.host, port: target.port
            )
            refreshCertificatePin()
            certificateStatus = "证书指纹已固定。返回设置后重新测试 WebDAV 连接。"
            verifiedFingerprint = ""
        } catch {
            certificateStatus = "无法保存证书信任：" +
                error.localizedDescription
        }
    }

    private func forgetCertificatePin() {
        guard let target = remoteEndpoint else { return }
        WebDAVCertificateTrust.remove(
            host: target.host, port: target.port
        )
        refreshCertificatePin()
        certificateStatus = "已撤销证书固定信任"
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
                    if settings.webDAVRemoteHost != value {
                        settings.disableRemoteCertificateCompatibility()
                    }
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
                    if settings.webDAVRemotePort != filtered {
                        settings.disableRemoteCertificateCompatibility()
                    }
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
                    if settings.webDAVRemotePath != value {
                        settings.disableRemoteCertificateCompatibility()
                    }
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
                    : settings.isRemoteCertificateCompatibilityEnabled
            },
            set: { value in
                if endpoint == .local {
                    settings.webDAVLocalAllowInvalidCertificate = value
                } else if value {
                    confirmRemoteTLSCompatibility = true
                } else {
                    settings.disableRemoteCertificateCompatibility()
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
