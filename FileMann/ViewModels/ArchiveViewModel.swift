import Foundation
import UIKit

@MainActor
final class ArchiveViewModel: ObservableObject {
    @Published var tasks: [ArchiveTask]
    @Published var sourceLocations: [SourceLocation]
    @Published var duplicateCandidates: [DuplicateCandidate]
    @Published var lastVerification: BatchVerification?
    @Published var settings: SMBSettings
    @Published var password: String
    @Published var webDAVPassword: String

    @Published var isRunning = false
    @Published var isRecheckingArchives = false
    @Published var isScanningLocation = false
    @Published var isShowingFilePicker = false
    @Published var isShowingFolderPicker = false
    @Published var isShowingSettings = false
    @Published var isShowingDuplicateReview = false
    @Published var statusMessage: String?
    @Published var connectionTestMessage: String?
    @Published var bytesPerSecond: Double = 0
    @Published var activeWebDAVEndpoint: String?
    @Published var configCenterPassword = KeychainStore.loadConfigCenterPassword()
    @Published var configCenterStatus: String?
    @Published var isConfigCenterSyncing = false

    private var worker: Task<Void, Never>?
    /// Invalidates an archive startup that is suspended inside an await
    /// when the entire task queue is cleared.
    private var queueGeneration = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var speedSampleDate = Date()
    private var speedSampleBytes: Int64 = 0
    private var notificationObservers: [NSObjectProtocol] = []

    // Retained only for the current upload batch. Avoid reconnecting,
    // re-running PUT/MOVE permission probes and re-downloading the same
    // duplicate candidates after each small HEIC finishes.
    private var webDAVBatchService: WebDAVArchiveService?
    private var webDAVBatchMode: WebDAVUploadMode?
    private var webDAVBatchSettings: SMBSettings?
    private var webDAVBatchPassword: String?
    private var checkedDuplicateTaskIDs = Set<UUID>()
    private var webDAVScheduling = false
    private var webDAVRefillRequested = false
    private var isRecoveringOnForeground = false

    // URLSession can emit a callback every few KB. Throttle visual updates
    // and persist the transfer checkpoint only about once per second.
    private var lastProgressUIUpdate: [UUID: Date] = [:]

    private func resetWebDAVBatchCache() {
        webDAVBatchService = nil
        webDAVBatchMode = nil
        webDAVBatchSettings = nil
        webDAVBatchPassword = nil
        checkedDuplicateTaskIDs.removeAll()
        lastProgressUIUpdate.removeAll()
        webDAVRefillRequested = false
    }

    init() {
        self.tasks = TaskStore.loadTasks().map { task in
            var value = task
            if value.state == .uploading {
                value.state = .paused
            }
            return value
        }
        self.sourceLocations = TaskStore.loadLocations()
        self.duplicateCandidates = TaskStore.loadDuplicates()
        self.lastVerification = TaskStore.loadVerification()
        self.settings = TaskStore.loadSettings()
        self.password = KeychainStore.loadPassword()
        self.webDAVPassword = KeychainStore.loadWebDAVPassword()

        // Older app versions may have already queued synthetic share names.
        // Do not silently upload them before the user chooses a filename.
        for index in tasks.indices {
            if tasks[index].isShareStaging == true,
               tasks[index].state != .completed,
               tasks[index].state != .skipped,
               tasks[index].shareFilenameDecision == nil,
               !FileMannShareFileNaming.isReliableOriginalFilename(
                    tasks[index].displayName
               ) {
                tasks[index].shareFilenameDecision = .pending
            }
        }

        if tasks.contains(where: {
            $0.state == .completed && $0.verifiedAt == nil
        }) {
            self.lastVerification = nil
            self.statusMessage =
                "存在旧版未核实的成功记录。请点击“核验已完成文件”查看实际 NAS 地址。"
        }

        let validTaskIDs = Set(tasks.map(\.id))
        self.duplicateCandidates.removeAll { !validTaskIDs.contains($0.taskID) }

        // Existing duplicates were already treated as completed without
        // uploading a new file. Keep that distinction across upgrades.
        let reusedTaskIDs = Set(duplicateCandidates.filter {
            $0.decision == .keepNAS || $0.decision == .keepBoth
        }.map(\.taskID))
        for index in tasks.indices {
            if tasks[index].state == .completed,
               tasks[index].completionKind == nil,
               reusedTaskIDs.contains(tasks[index].id) {
                tasks[index].completionKind = .alreadyOnNAS
            }
        }

        installWebDAVObservers()

        Task { [weak self] in
            await self?.restoreWebDAVBackgroundTasks()
        }
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var totalBytes: Int64 {
        tasks.filter { $0.state != .skipped }.reduce(0) { $0 + $1.fileSize }
    }

    var transferredBytes: Int64 {
        tasks.filter { $0.state != .skipped }.reduce(0) { $0 + min($1.transferredBytes, $1.fileSize) }
    }

    var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    var completedCount: Int {
        tasks.filter {
            $0.state == .completed && $0.verifiedAt != nil
        }.count
    }

    var unresolvedDuplicateCount: Int {
        duplicateCandidates.filter { $0.decision == .unresolved }.count
    }

    var unresolvedShareNamesCount: Int {
        tasks.filter { $0.needsShareFilenameDecision }.count
    }

    /// Imports shared-file references into the persistent queue without
    /// copying their bytes into FileMann's private media library.
    func importShareInbox() {
        guard let inbox = try? FileMannShareGroup.incomingDirectory(
            createIfMissing: false
        ) else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        var added = 0
        for url in urls {
            do {
                guard FileMannShared.isSupportedMediaFile(url) else {
                    continue
                }
                let values = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .fileSizeKey,
                        .contentModificationDateKey
                    ]
                )
                guard values.isRegularFile == true,
                      let bytes = values.fileSize, bytes > 0 else {
                    continue
                }

                // The share extension reuses the same staged file across
                // launches until a verified upload deletes it.
                let fileKey = url.lastPathComponent
                if tasks.contains(where: {
                    $0.isShareStaging == true &&
                    $0.sourceRelativePath == fileKey
                }) {
                    continue
                }

                let parts = fileKey.components(separatedBy: "__")
                let displayName = parts.count > 1
                    ? parts.dropFirst().joined(separator: "__")
                    : fileKey
                let metadata = FileMannShareFileNaming.readMetadata(for: url)
                let requiresNaming = metadata?.needsFilenameDecision ??
                    FileMannShareFileNaming.isGeneratedPlaceholderName(
                        displayName
                    )
                let bookmark = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                var task = ArchiveTask(
                    bookmark: bookmark,
                    displayName: displayName,
                    remoteFileName: uniqueRemoteName(for: displayName),
                    sourceRelativePath: fileKey,
                    fileSize: Int64(bytes),
                    sourceModifiedAt: values.contentModificationDate
                )
                task.isShareStaging = true
                task.shareSelectionIndex = metadata?.selectionIndex
                task.shareFilenameDecision = requiresNaming
                    ? .pending : .original
                tasks.append(task)
                added += 1
            } catch {
                // Keep unreadable files in staging for later retry.
                continue
            }
        }

        guard added > 0 else { return }
        invalidateVerification()
        persistTasks()
        let unnamed = tasks.filter { $0.needsShareFilenameDecision }.count
        statusMessage = "已从相册分享导入 \(added) 项；" +
            (unnamed > 0
                ? "\(unnamed) 项尚未确认文件名，请按相册序号和预览选择名称"
                : "已加入持久化队列")
    }

    func addDocuments(_ urls: [URL]) {
        var added = 0
        var failures: [String] = []

        for url in urls {
            do {
                let didStart = url.startAccessingSecurityScopedResource()
                defer {
                    if didStart {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let bookmark = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let values = try url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .nameKey
                ])

                let size = Int64(values.fileSize ?? 0)
                let name = values.name ?? url.lastPathComponent
                let remoteName = uniqueRemoteName(for: name)

                let item = ArchiveTask(
                    bookmark: bookmark,
                    displayName: name,
                    remoteFileName: remoteName,
                    fileSize: size,
                    sourceModifiedAt: values.contentModificationDate
                )
                tasks.append(item)
                added += 1
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        invalidateVerification()
        persistTasks()

        if failures.isEmpty {
            statusMessage = "已加入 \(added) 个文件"
        } else {
            statusMessage = "加入 \(added) 个，失败 \(failures.count) 个\n" + failures.prefix(3).joined(separator: "\n")
        }
    }

    func addSourceLocation(_ url: URL) {
        do {
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            guard values.isDirectory == true else {
                statusMessage = "请选择文件夹位置"
                return
            }

            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let location = SourceLocation(
                bookmark: bookmark,
                displayName: values.name ?? url.lastPathComponent
            )
            sourceLocations.append(location)
            persistLocations()
            statusMessage = "已添加位置：\(location.displayName)"
            scanLocation(location.id)
        } catch {
            statusMessage = "添加位置失败：\(error.localizedDescription)"
        }
    }

    func scanLocation(_ locationID: UUID) {
        guard !isScanningLocation,
              let location = sourceLocations.first(where: { $0.id == locationID }) else {
            return
        }

        isScanningLocation = true
        statusMessage = "正在扫描 \(location.displayName)…"

        Task {
            do {
                let scanned = try await Task.detached(priority: .userInitiated) {
                    try Self.scanLocationFiles(location)
                }.value

                var added = 0
                for item in scanned.tasks {
                    let alreadyExists = tasks.contains { existing in
                        guard existing.sourceLocationID == location.id,
                              existing.sourceRelativePath == item.sourceRelativePath else {
                            return false
                        }
                        let sameSize = existing.fileSize == item.fileSize
                        let sameDate: Bool
                        if let a = existing.sourceModifiedAt, let b = item.sourceModifiedAt {
                            sameDate = abs(a.timeIntervalSince(b)) <= 1
                        } else {
                            sameDate = existing.sourceModifiedAt == nil && item.sourceModifiedAt == nil
                        }
                        return sameSize && sameDate
                    }

                    if !alreadyExists {
                        tasks.append(item)
                        added += 1
                    }
                }

                if let index = sourceLocations.firstIndex(where: { $0.id == location.id }) {
                    sourceLocations[index].lastScannedAt = Date()
                    sourceLocations[index].lastFileCount = scanned.fileCount
                    sourceLocations[index].lastTotalBytes = scanned.totalBytes
                }

                invalidateVerification()
                persistTasks()
                persistLocations()
                statusMessage = "扫描完成：\(scanned.fileCount) 个文件，\(ByteFormat.string(scanned.totalBytes))；新增 \(added) 个任务"
            } catch {
                statusMessage = "扫描位置失败：\(error.localizedDescription)"
            }
            isScanningLocation = false
        }
    }

    func removeSourceLocation(_ location: SourceLocation) {
        sourceLocations.removeAll { $0.id == location.id }
        persistLocations()
    }

    func saveSettings() {
        settings.transport = .webDAV
        TaskStore.saveSettings(settings)
        do {
            try KeychainStore.saveWebDAVPassword(webDAVPassword)
            statusMessage = "归档设置已保存"
        } catch {
            statusMessage = "密码保存失败：\(error.localizedDescription)"
        }
    }

    // Download only this app's private configuration. Running uploads
    // retain their original endpoint and will not be reconfigured mid-flight.
    func syncConfigCenter(silent: Bool = false) {
        guard !isConfigCenterSyncing else { return }
        let fixedPassword = configCenterPassword
        guard !fixedPassword.isEmpty else {
            if !silent { configCenterStatus = "请输入配置中心固定密码" }
            return
        }

        isConfigCenterSyncing = true
        if !silent { configCenterStatus = "正在读取 FileMann 配置…" }

        Task {
            defer { isConfigCenterSyncing = false }
            do {
                let remote = try await ConfigCenterClient.fetch(
                    password: fixedPassword
                )
                guard !tasks.contains(where: { $0.state == .uploading }) else {
                    configCenterStatus = "有任务正在传输；完成后才能应用配置"
                    return
                }
                let updated = try remote.applying(to: settings)

                // A private config-center record may still point at an old
                // NAS IP. Never silently replace a manually corrected LAN
                // endpoint at launch; require an explicit sync to migrate.
                if silent {
                    let current = settings.normalizedWebDAVBaseURL
                    let incoming = updated.normalizedWebDAVBaseURL
                    // Host-only comparison is insufficient: an obsolete
                    // WebDAV port or share path can also cause PUT 403.
                    if !current.isEmpty && !incoming.isEmpty &&
                        current != incoming {
                        configCenterStatus =
                            "配置中心 WebDAV 端点与本机不同（地址/端口/路径），" +
                            "保留本机设置；请在配置中心核对后手动同步。"
                        return
                    }
                }

                try KeychainStore.saveConfigCenterPassword(fixedPassword)
                try KeychainStore.saveWebDAVPassword(
                    remote.webdav?.password ?? webDAVPassword
                )
                webDAVPassword = remote.webdav?.password ?? webDAVPassword
                settings = updated
                TaskStore.saveSettings(updated)
                var missing: [String] = []
                if updated.normalizedWebDAVRemoteBaseURL.isEmpty {
                    missing.append("外网 WebDAV 地址")
                }
                if !updated.hasWebDAVArchiveDirectory {
                    missing.append("归档目录")
                }
                if updated.webDAVUsername.isEmpty ||
                    webDAVPassword.isEmpty {
                    missing.append("NAS 账号凭据")
                }
                configCenterStatus = missing.isEmpty
                    ? "WebDAV 配置已读取；请运行“测试连接与写入权限”完成验收"
                    : "已同步 WebDAV 配置；服务端待补齐：" +
                        missing.joined(separator: "、")
            } catch {
                configCenterStatus =
                    "同步失败：\(error.localizedDescription)。原配置保持不变"
            }
        }
    }

    func chooseRemoteDirectory(_ path: String) {
        settings.webDAVRemoteDirectory = path
        saveSettings()
    }

    func loadRemoteDirectories(at path: String) async throws -> [SMBDirectoryEntry] {
        let service = try await makeReachableWebDAVService()
        return try await service.listDirectories(at: path)
    }

    /// Check a selected WebDAV directory before saving it as the archive
    /// destination. Never attempt to create the SMB share or a guessed root.
    func verifyWebDAVArchiveDirectory(at path: String) async throws {
        let service = try await makeReachableWebDAVService()
        do {
            try await service.verifyWritableDirectory(at: path)
        } catch {
            throw NSError(
                domain: "FileMann.WebDAV.WritePermission",
                code: (error as NSError).code,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "目标地址：\(service.baseURLString)" +
                        (path.isEmpty ? "/" : "/\(path)") +
                        "\n\(error.localizedDescription)"
                ]
            )
        }
    }

    func testConnection() {
        connectionTestMessage = "连接中…"
        Task {
            do {
                let service = try await makeReachableWebDAVService()
                let mode = try await service.preferredUploadMode()
                connectionTestMessage =
                    "连接成功（" + (activeWebDAVEndpoint ?? "NAS") +
                    "）；" + (mode == .atomicMove
                        ? "PUT / MOVE 已验证，可原子重命名"
                        : "PUT 已验证，NAS 不支持 MOVE，启用直传模式")
            } catch {
                connectionTestMessage =
                    "WebDAV 连接或写入测试失败（" +
                    (activeWebDAVEndpoint ?? "NAS") + "）：" +
                    error.localizedDescription
            }
        }
    }

    func setDuplicateDecision(_ candidateID: UUID, decision: DuplicateDecision) {
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == candidateID }) else { return }
        duplicateCandidates[index].decision = decision
        persistDuplicates()

        if unresolvedDuplicateCount == 0 {
            statusMessage = "重复项已处理，点“开始归档”继续"
        }
    }

    func applyDecisionToAllUnresolved(_ decision: DuplicateDecision) {
        for index in duplicateCandidates.indices where duplicateCandidates[index].decision == .unresolved {
            duplicateCandidates[index].decision = decision
        }
        persistDuplicates()
        statusMessage = "重复项已处理，点“开始归档”继续"
    }

    func start() {
        guard !isRunning else { return }
        TaskStore.setShouldResumeArchive(true)
        // No SMB fallback: all new and restored tasks use the system-backed
        // WebDAV upload manager for local or remote transfer.
        settings.transport = .webDAV
        // A manual start begins a fresh batch. Auto-refills in the same
        // batch use retryFailed:false and retain the cached preflight.
        resetWebDAVBatchCache()
        startWebDAV()
    }

    func pause() {
        if settings.transport == .webDAV {
            TaskStore.setShouldResumeArchive(false)
            queueGeneration += 1
            resetWebDAVBatchCache()
            WebDAVBackgroundUploadManager.shared.suspendAll()
            isRunning = false
            for index in tasks.indices where tasks[index].state == .uploading {
                tasks[index].state = .paused
            }
            persistTasks()
            statusMessage = "后台上传已暂停，可稍后继续"
            return
        }

        worker?.cancel()
        worker = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()

        for index in tasks.indices where tasks[index].state == .uploading {
            tasks[index].state = .paused
        }
        persistTasks()
        statusMessage = "已暂停，可稍后继续"
    }

    func retry(_ task: ArchiveTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              tasks[index].state != .completed else { return }
        tasks[index].state = .queued
        tasks[index].transferredBytes = 0
        tasks[index].remoteVerifiedPath = nil
        tasks[index].remoteEndpointURL = nil
        tasks[index].attemptedRemotePath = nil
        tasks[index].verifiedAt = nil
        tasks[index].completionKind = nil
        tasks[index].errorMessage = nil
        invalidateVerification()
        persistTasks()
    }

    func removeTask(_ task: ArchiveTask) {
        if settings.transport == .webDAV {
            WebDAVBackgroundUploadManager.shared.cancel(taskID: task.id)
        }
        // Removing any share task (including a queued one) must discard
        // its own staged copy and metadata. Otherwise the next app launch
        // would silently recreate the removed task.
        if task.isShareStaging == true,
           let inbox = try? FileMannShareGroup.incomingDirectory(
               createIfMissing: false
           ),
           let url = try? resolveBookmark(task.bookmark),
           url.deletingLastPathComponent().standardizedFileURL ==
               inbox.standardizedFileURL {
            try? FileMannShareFileNaming.discardStagedFile(url)
        }
        tasks.removeAll { $0.id == task.id }
        duplicateCandidates.removeAll { $0.taskID == task.id }
        invalidateVerification()
        persistTasks()
        persistDuplicates()
    }

    /// Rename only the queued share import. The App Group staging filename
    /// and Photos original are unaffected; only the future NAS name changes.
    func renameQueuedSharedMedia(_ task: ArchiveTask, to proposed: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              (!isRunning || tasks[index].needsShareFilenameDecision),
              tasks[index].isShareStaging == true,
              [.queued, .failed, .missingSource]
                  .contains(tasks[index].state) else {
            statusMessage = "只能修改尚未归档的相册分享文件"
            return
        }
        // A manual rename is explicit; never silently sanitize, truncate,
        // normalize Unicode, or change the extension's case.
        let requested = proposed
        guard !requested.isEmpty,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              requested != ".", requested != "..",
              !requested.contains("/"),
              !requested.contains("\\"),
              !requested.contains("\0") else {
            statusMessage = "文件名包含不允许的路径字符；不会擅自替换或截断"
            return
        }
        let renamed = requested
        let otherNames = Set(tasks.filter { $0.id != task.id }
            .map { $0.remoteFileName.lowercased() })
        var remoteName = renamed
        var sequence = 2
        while otherNames.contains(remoteName.lowercased()) {
            remoteName = FileMannShareFileNaming.addingDuplicateSuffix(
                to: renamed, number: sequence
            )
            sequence += 1
        }
        tasks[index].displayName = renamed
        tasks[index].remoteFileName = remoteName
        tasks[index].shareFilenameDecision = .userRenamed
        tasks[index].remoteRelativePath = nil
        tasks[index].remoteEndpointURL = nil
        tasks[index].attemptedRemotePath = nil
        tasks[index].remoteVerifiedPath = nil
        tasks[index].verifiedAt = nil
        tasks[index].completionKind = nil
        tasks[index].transferredBytes = 0
        tasks[index].state = .queued
        tasks[index].errorMessage = nil
        duplicateCandidates.removeAll { $0.taskID == task.id }
        invalidateVerification()
        persistTasks()
        persistDuplicates()
        statusMessage = "归档文件名已改为 \(remoteName)，相册原件不受影响"
    }

    /// Explicit consent to use the temporary filename. The NAS collision
    /// guard still adds (2), (3) instead of overwriting an existing file.
    func approvePlaceholderName(for task: ArchiveTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              (!isRunning || tasks[index].needsShareFilenameDecision),
              tasks[index].isShareStaging == true,
              tasks[index].needsShareFilenameDecision,
              [.queued, .failed, .missingSource].contains(
                  tasks[index].state
              ) else { return }

        tasks[index].shareFilenameDecision = .placeholderApproved
        tasks[index].state = .queued
        tasks[index].transferredBytes = 0
        tasks[index].errorMessage =
            "已选择使用占位文件名；发生重名时自动追加数字后缀"
        duplicateCandidates.removeAll { $0.taskID == task.id }
        invalidateVerification()
        persistTasks()
        persistDuplicates()
        statusMessage = "已确认占位文件名：" +
            tasks[index].remoteFileName
    }

    /// Diagnose old success records without modifying any NAS or phone file.
    /// A legacy same-name/same-size match is a location *candidate*, not
    /// proof that the old upload actually wrote this file.
    func recheckCompletedArchives() {
        guard !isRecheckingArchives, !isRunning else { return }
        isRecheckingArchives = true
        statusMessage = "正在只读核验任务记录对应的实际 NAS 路径…"
        Task {
            defer {
                isRecheckingArchives = false
                persistTasks()
            }
            var confirmed = 0
            var foundLegacy = 0
            var missing = 0
            for index in tasks.indices {
                guard tasks[index].state == .completed else { continue }
                let snapshot = tasks[index]
                let path = snapshot.remoteVerifiedPath ??
                    snapshot.attemptedRemotePath ??
                    (snapshot.remoteRelativePath ?? snapshot.remoteFileName)
                let endpoints = snapshot.remoteEndpointURL.map { [$0] } ??
                    settings.webDAVCandidateBaseURLs
                var located = false

                for endpoint in endpoints {
                    do {
                        let service = try WebDAVArchiveService(
                            settings: settings,
                            password: webDAVPassword,
                            baseURLString: endpoint
                        )
                        let result = try await service.verifyPublishedFile(
                            at: path,
                            expectedBytes: snapshot.fileSize
                        )
                        tasks[index].remoteEndpointURL = endpoint
                        tasks[index].remoteVerifiedPath = result.remotePath
                        tasks[index].attemptedRemotePath = path

                        if snapshot.verifiedAt != nil {
                            tasks[index].verifiedAt = Date()
                            tasks[index].errorMessage = "已在原上传端点的目标目录重新确认"
                            confirmed += 1
                        } else {
                            // Old app did not record its upload endpoint.
                            // Do not equate a size match to proven delivery.
                            tasks[index].verifiedAt = nil
                            tasks[index].errorMessage =
                                "旧版上传来源未记录：已发现同名同大小候选文件，" +
                                "但不能确认就是本次上传；不会自动删除原件"
                            foundLegacy += 1
                        }
                        located = true
                        break
                    } catch {
                        continue
                    }
                }
                if !located {
                    tasks[index].verifiedAt = nil
                    tasks[index].errorMessage =
                        "未在记录的 WebDAV 目录中找到该文件；请核对实际共享映射"
                    missing += 1
                }
            }
            lastVerification = await verifyRecordedWebDAVManifest()
            TaskStore.saveVerification(lastVerification)
            statusMessage =
                "核验结束：确认 \(confirmed) 个；旧版找到候选 \(foundLegacy) 个；" +
                "未找到 \(missing) 个。点击任务查看并复制实际地址。"
        }
    }

    /// A successful upload always remains pinned to its original endpoint.
    /// Group completed tasks by that endpoint and parent directory so the
    /// final manifest needs a single PROPFIND per directory rather than
    /// N repeated listings (which can contain thousands of HEIC files).
    private func verifyRecordedWebDAVManifest() async -> BatchVerification {
        let expected = tasks.filter { $0.state != .skipped }
        let completed = expected.compactMap { task -> (
            endpoint: String, path: String, bytes: Int64
        )? in
            guard task.state == .completed,
                  task.verifiedAt != nil,
                  let endpoint = task.remoteEndpointURL,
                  let path = task.remoteVerifiedPath else {
                return nil
            }
            return (
                endpoint: endpoint,
                path: path,
                bytes: task.fileSize
            )
        }

        var verifiedCount = 0
        var verifiedBytes: Int64 = 0
        let byEndpoint = Dictionary(grouping: completed) {
            $0.endpoint
        }

        for (endpoint, entries) in byEndpoint {
            do {
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: webDAVPassword,
                    baseURLString: endpoint
                )
                let verified = await service.verifyPublishedBatch(
                    entries.map { (
                        path: $0.path, expectedBytes: $0.bytes
                    ) }
                )
                for item in entries {
                    if verified[item.path] == item.bytes {
                        verifiedCount += 1
                        verifiedBytes += item.bytes
                    }
                }
            } catch {
                // Never fall back to a different local/WAN endpoint when
                // checking the recorded upload's actual storage path.
                continue
            }
        }

        return BatchVerification(
            expectedCount: expected.count,
            expectedBytes: expected.reduce(Int64(0)) {
                $0 + $1.fileSize
            },
            verifiedCount: verifiedCount,
            verifiedBytes: verifiedBytes,
            checkedAt: Date()
        )
    }

    /// Explicitly discard the complete local archive queue. This does not
    /// delete any NAS object or the user's Photos originals. Only files
    /// owned by FileMann's disposable App Group Incoming-Share directory
    /// are purged, so importing will not re-add cleared entries on launch.
    func clearAllTasks() {
        TaskStore.setShouldResumeArchive(false)
        queueGeneration += 1
        resetWebDAVBatchCache()
        worker?.cancel()
        worker = nil
        WebDAVBackgroundUploadManager.shared.cancelAll()
        isRunning = false
        bytesPerSecond = 0
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()

        tasks.removeAll()
        duplicateCandidates.removeAll()
        invalidateVerification()
        persistTasks()
        persistDuplicates()

        // The directory is exclusively owned by FileMann's Share Extension.
        // No Photos library URL, source location, or NAS path is touched.
        var cleanupFailures = 0
        if let inbox = try? FileMannShareGroup.incomingDirectory(
            createIfMissing: false
        ), let urls = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        ) {
            for url in urls {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    cleanupFailures += 1
                }
            }
        }

        statusMessage = cleanupFailures == 0
            ? "已清空全部归档任务并请求取消正在进行的上传；" +
              "NAS 已有文件和相册原件未删除"
            : "任务已清空，但有 \(cleanupFailures) 个分享暂存文件无法清理，" +
              "请稍后重试清理；NAS 和相册原件未删除"
    }

    func clearCompleted() {
        let removedIDs = Set(tasks.filter {
            ($0.state == .completed && $0.verifiedAt != nil) ||
                $0.state == .skipped
        }.map(\.id))
        tasks.removeAll { removedIDs.contains($0.id) }
        duplicateCandidates.removeAll { removedIDs.contains($0.taskID) }
        invalidateVerification()
        persistTasks()
        persistDuplicates()
    }

    func task(for candidate: DuplicateCandidate) -> ArchiveTask? {
        tasks.first { $0.id == candidate.taskID }
    }

    private func startWebDAV(retryFailed: Bool = true) {
        let generation = queueGeneration
        guard settings.isValid else {
            statusMessage = "请先配置 QNAP WebDAV 地址"
            isShowingSettings = true
            return
        }

        guard settings.hasWebDAVArchiveDirectory else {
            statusMessage =
                "请先选择 QNAP 共享文件夹作为归档目录；WebDAV 根目录 / 只能用于浏览，不能直接归档"
            isShowingSettings = true
            return
        }

        if unresolvedDuplicateCount > 0 {
            isShowingDuplicateReview = true
            statusMessage = "请先处理 \(unresolvedDuplicateCount) 个重复文件"
            return
        }

        if webDAVScheduling {
            webDAVRefillRequested = true
            return
        }
        webDAVScheduling = true

        saveSettings()

        for index in tasks.indices {
            if (retryFailed && tasks[index].state == .failed) ||
                (retryFailed && tasks[index].state == .paused) ||
                (retryFailed && tasks[index].state == .missingSource) {
                tasks[index].state = .queued
                tasks[index].errorMessage = nil
            }
        }
        persistTasks()

        let wasAlreadyRunning = isRunning
        isRunning = true
        if !wasAlreadyRunning {
            speedSampleDate = Date()
            speedSampleBytes = transferredBytes
            bytesPerSecond = 0
        }

        Task {
            defer {
                webDAVScheduling = false
                if webDAVRefillRequested {
                    webDAVRefillRequested = false
                    if generation == queueGeneration && isRunning &&
                        tasks.contains(where: { $0.state == .queued }) {
                        startWebDAV(retryFailed: false)
                    }
                }
            }

            do {
                let service: WebDAVArchiveService
                let uploadMode: WebDAVUploadMode
                if let cached = webDAVBatchService,
                   let cachedMode = webDAVBatchMode,
                   webDAVBatchSettings == settings,
                   webDAVBatchPassword == webDAVPassword {
                    service = cached
                    uploadMode = cachedMode
                } else {
                    resetWebDAVBatchCache()
                    // Only the first file in a batch needs to prove the
                    // destination is really writable, via PUT/MOVE/DELETE.
                    // Every subsequent file reuses the pinned endpoint.
                    let resolved = try await makeReachableWebDAVService()
                    guard generation == queueGeneration else { return }
                    let mode = try await resolved.preferredUploadMode()
                    guard generation == queueGeneration else { return }
                    webDAVBatchService = resolved
                    webDAVBatchMode = mode
                    webDAVBatchSettings = settings
                    webDAVBatchPassword = webDAVPassword
                    service = resolved
                    uploadMode = mode
                }
                guard generation == queueGeneration else { return }

                let foundNewDuplicates = try await scanForDuplicates(using: service)
                guard generation == queueGeneration else { return }
                if foundNewDuplicates || unresolvedDuplicateCount > 0 {
                    isShowingDuplicateReview = true
                    isRunning = false
                    statusMessage = "发现 \(unresolvedDuplicateCount) 个内容完全相同的文件，请先选择保留方式"
                    return
                }

                try await applyResolvedDuplicates(using: service)
                guard generation == queueGeneration else { return }

                let manager = WebDAVBackgroundUploadManager.shared
                let existingTaskIDs = await manager.activeTaskIDs()
                guard generation == queueGeneration else { return }
                manager.resumeAll()

                // Two small image uploads overlap WebDAV round trips.
                // Large videos remain strictly serial to bound the
                // background session's additional iOS staging copies.
                var scheduled = 0
                var inFlightSizes = tasks.filter {
                    existingTaskIDs.contains($0.id)
                }.map(\.fileSize)
                for index in tasks.indices {
                    guard generation == queueGeneration else { return }
                    guard tasks[index].state == .queued else {
                        continue
                    }
                    if tasks[index].fileSize <= 0 {
                        tasks[index].state = .failed
                        tasks[index].errorMessage =
                            "源文件大小为 0，已跳过空文件；不会阻塞其他媒体上传"
                        continue
                    }
                    guard WebDAVUploadSchedulingPolicy.canSchedule(
                        fileSize: tasks[index].fileSize,
                        inFlightSizes: inFlightSizes
                    ) else {
                        if inFlightSizes.contains(tasks[index].fileSize) {
                            // Two same-sized media need an intervening
                            // NAS duplicate check; other distinct HEICs
                            // can be handed to the daemon already.
                            continue
                        }
                        break
                    }

                    let taskID = tasks[index].id
                    if existingTaskIDs.contains(taskID) {
                        tasks[index].state = .uploading
                        continue
                    }

                    do {
                        let snapshot = tasks[index]
                        if snapshot.needsShareFilenameDecision ||
                            (snapshot.isShareStaging == true &&
                             snapshot.shareFilenameDecision == nil &&
                             !FileMannShareFileNaming.isReliableOriginalFilename(
                                 snapshot.displayName
                             )) {
                            tasks[index].errorMessage =
                                "原文件名未知：请自定义名称或选择使用占位文件名"
                            continue
                        }
                        let sourceURL = try resolveBookmark(snapshot.bookmark)

                        // Keep the exact source filename unless the NAS
                        // already has an entry at the destination. Preserve
                        // every Unicode character, space and extension case.
                        let sourceName = snapshot.remoteRelativePath.map {
                            ($0 as NSString).lastPathComponent
                        } ?? snapshot.displayName
                        let relativeDirectory = snapshot.remoteRelativePath.map {
                            ($0 as NSString).deletingLastPathComponent
                        }
                        var candidate = snapshot
                        var finalPath = service.desiredRemotePath(for: candidate)
                        var suffix = 2
                        while await service.remoteFileSize(atPath: finalPath) != nil {
                            guard suffix <= 10000 else {
                                throw WebDAVArchiveError.remoteConflict(sourceName)
                            }
                            let nextName = FileMannShareFileNaming
                                .addingDuplicateSuffix(to: sourceName, number: suffix)
                            candidate.remoteFileName = nextName
                            if let relativeDirectory {
                                candidate.remoteRelativePath =
                                    relativeDirectory.isEmpty ||
                                    relativeDirectory == "."
                                    ? nextName
                                    : (relativeDirectory as NSString)
                                        .appendingPathComponent(nextName)
                            }
                            finalPath = service.desiredRemotePath(for: candidate)
                            suffix += 1
                        }

                        tasks[index].remoteFileName = candidate.remoteFileName
                        tasks[index].remoteRelativePath = candidate.remoteRelativePath
                        try await service.prepareParentDirectory(for: finalPath)
                        guard generation == queueGeneration else { return }

                        let partialPath = uploadMode == .atomicMove
                            ? finalPath + ".filemann-" + taskID.uuidString.lowercased() + ".partial"
                            : finalPath
                        let request = try service.makeUploadRequest(
                            path: partialPath,
                            failIfExists: uploadMode == .directPut
                        )

                        tasks[index].remoteEndpointURL = service.baseURLString
                        tasks[index].attemptedRemotePath = finalPath
                        tasks[index].verifiedAt = nil
                        tasks[index].completionKind = nil

                        try manager.schedule(
                            taskID: taskID,
                            sourceURL: sourceURL,
                            request: request,
                            partialPath: partialPath,
                            finalPath: finalPath,
                            expectedBytes: snapshot.fileSize,
                            baseURLString: service.baseURLString,
                            uploadMode: uploadMode
                        )

                        tasks[index].state = .uploading
                        tasks[index].errorMessage = candidate.remoteFileName ==
                            snapshot.displayName
                            ? "iOS 后台上传中 · 保留原文件名"
                            : "iOS 后台上传中 · 重名后缀：" +
                                candidate.remoteFileName
                        scheduled += 1
                        inFlightSizes.append(snapshot.fileSize)
                    } catch {
                        tasks[index].state = isSourceAccessError(error)
                            ? .missingSource
                            : .failed
                        tasks[index].errorMessage = error.localizedDescription
                    }
                }

                persistTasks()

                if scheduled > 0 || tasks.contains(where: { $0.state == .uploading }) {
                    statusMessage = "已交给 iOS 后台上传；可以锁屏或切换到其他 App"
                } else if unresolvedShareNamesCount > 0 {
                    isRunning = false
                    statusMessage = "有 \(unresolvedShareNamesCount) 项待确认文件名，" +
                        "请在列表里选择“自定义文件名”或“使用占位名”"
                } else {
                    isRunning = false
                    await finishWebDAVBatchIfPossible()
                }
            } catch is CancellationError {
                isRunning = false
                statusMessage = "已暂停"
            } catch {
                isRunning = false
                statusMessage = "WebDAV 处理失败：\(error.localizedDescription)"
            }
        }
    }

    private func scanForDuplicates(using service: WebDAVArchiveService) async throws -> Bool {
        let knownTaskIDs = Set(duplicateCandidates.map(\.taskID))
        let sizeCounts = Dictionary(
            tasks.filter { $0.state != .skipped }
                .map { ($0.fileSize, 1) },
            uniquingKeysWith: +
        )
        let candidates = tasks.filter {
            [.queued, .paused, .failed, .missingSource]
                .contains($0.state) &&
            !knownTaskIDs.contains($0.id) &&
            !checkedDuplicateTaskIDs.contains($0.id) &&
            !$0.needsShareFilenameDecision
        }

        guard !candidates.isEmpty else { return false }

        var found = false
        for (offset, task) in candidates.enumerated() {
            try Task.checkCancellation()
            statusMessage =
                "正在通过 WebDAV 检查重复文件 \(offset + 1)/\(candidates.count)：\(task.displayName)"

            do {
                let sourceURL = try resolveBookmark(task.bookmark)
                if let remote = try await service.findExactDuplicate(
                    task: task,
                    sourceURL: sourceURL
                ) {
                    guard tasks.contains(where: { $0.id == task.id }) else {
                        return false
                    }
                    duplicateCandidates.append(
                        DuplicateCandidate(
                            taskID: task.id,
                            remotePath: remote.path,
                            remoteName: remote.name,
                            fileSize: remote.size
                        )
                    )
                    found = true
                    persistDuplicates()
                }
                // Unique-sized batch items cannot be byte-identical to
                // another selected file. Reuse their negative scan; when
                // sizes repeat, recheck after the first upload publishes,
                // so intra-batch duplicates still reach review.
                if sizeCounts[task.fileSize] == 1 {
                    checkedDuplicateTaskIDs.insert(task.id)
                }
            } catch WebDAVArchiveError.sourceUnavailable {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].state = .missingSource
                    tasks[index].errorMessage =
                        WebDAVArchiveError.sourceUnavailable.localizedDescription
                }
            }
        }

        return found
    }

    private func applyResolvedDuplicates(using service: WebDAVArchiveService) async throws {
        for candidate in duplicateCandidates where candidate.decision != .unresolved {
            guard let index = tasks.firstIndex(where: { $0.id == candidate.taskID }),
                  tasks[index].state != .completed,
                  tasks[index].state != .skipped else {
                continue
            }

            switch candidate.decision {
            case .unresolved:
                break

            case .keepNAS:
                _ = try await service.verifyPublishedFile(
                    at: candidate.remotePath,
                    expectedBytes: candidate.fileSize
                )
                tasks[index].state = .completed
                tasks[index].transferredBytes = tasks[index].fileSize
                tasks[index].remoteVerifiedPath = candidate.remotePath
                tasks[index].attemptedRemotePath =
                    service.desiredRemotePath(for: tasks[index])
                tasks[index].remoteEndpointURL = service.baseURLString
                tasks[index].verifiedAt = Date()
                tasks[index].completionKind = .alreadyOnNAS
                tasks[index].shouldDeleteSource = true
                tasks[index].errorMessage =
                    "重复文件：使用 NAS 已有副本，整批校验后删除手机副本"

            case .keepPhone:
                try await service.deleteRemoteFile(at: candidate.remotePath)
                tasks[index].state = .skipped
                tasks[index].transferredBytes = 0
                tasks[index].shouldDeleteSource = false
                tasks[index].errorMessage =
                    "重复文件：已删除 NAS 副本，仅保留手机文件"

            case .keepBoth:
                _ = try await service.verifyPublishedFile(
                    at: candidate.remotePath,
                    expectedBytes: candidate.fileSize
                )
                tasks[index].state = .completed
                tasks[index].transferredBytes = tasks[index].fileSize
                tasks[index].remoteVerifiedPath = candidate.remotePath
                tasks[index].attemptedRemotePath =
                    service.desiredRemotePath(for: tasks[index])
                tasks[index].remoteEndpointURL = service.baseURLString
                tasks[index].verifiedAt = Date()
                tasks[index].completionKind = .alreadyOnNAS
                tasks[index].shouldDeleteSource = false
                tasks[index].errorMessage =
                    "重复文件：两边都保留，不重复上传"
            }

            persistTasks()
        }
    }

    private func installWebDAVObservers() {
        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(
                forName: .fileMannWebDAVProgress,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let taskID = note.userInfo?["taskID"] as? UUID,
                      let sent = note.userInfo?["sent"] as? Int64 else {
                    return
                }

                Task { @MainActor in
                    guard let self,
                          let index = self.tasks.firstIndex(where: {
                              $0.id == taskID
                          }),
                          ![ArchiveTaskState.completed, .skipped, .failed]
                            .contains(self.tasks[index].state) else {
                        return
                    }
                    // An in-flight URLSession callback may arrive just
                    // after the user presses Pause. Never let that event
                    // silently reactivate the task or refill the queue.
                    if self.tasks[index].state == .paused &&
                        !self.isRunning {
                        return
                    }
                    self.isRunning = true
                    if self.tasks[index].state != .uploading {
                        self.tasks[index].state = .uploading
                        self.persistTasks()
                    }
                    self.updateProgress(id: taskID, bytes: sent)
                    // The progress checkpoint is written by updateProgress
                    // at 1 Hz, not for every URLSession body-data callback.
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .fileMannWebDAVCompleted,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let taskID = note.userInfo?["taskID"] as? UUID,
                      let remotePath = note.userInfo?["remotePath"] as? String,
                      let remoteSize = note.userInfo?["remoteSize"] as? Int64,
                      let endpoint = note.userInfo?["remoteEndpointURL"] as? String else {
                    return
                }

                Task { @MainActor in
                    guard let self,
                          let index = self.tasks.firstIndex(where: { $0.id == taskID }) else {
                        return
                    }

                    self.tasks[index].transferredBytes = remoteSize
                    self.tasks[index].remoteVerifiedPath = remotePath
                    self.tasks[index].remoteEndpointURL = endpoint
                    self.tasks[index].attemptedRemotePath = remotePath
                    self.tasks[index].verifiedAt = Date()
                    self.tasks[index].completionKind = .uploaded
                    self.tasks[index].state = .completed
                    self.tasks[index].errorMessage =
                        "已在实际上传端点的目录列表中确认文件"
                    self.cleanupShareStaging(at: index)
                    self.persistTasks()
                    // Receipt can be discarded only after the normal task
                    // store has the verified endpoint/path and file size.
                    WebDAVBackgroundReceiptStore.remove(taskID: taskID)
                    // Inventory is only a duplicate-check cache; any
                    // newly queued file must see the updated NAS listing.
                    if self.webDAVBatchService?.baseURLString == endpoint {
                        self.webDAVBatchService?.invalidateRemoteInventory()
                    }
                    self.lastProgressUIUpdate.removeValue(forKey: taskID)
                    let hasUploadableQueue = self.tasks.contains {
                        $0.state == .queued &&
                        !$0.needsShareFilenameDecision
                    }
                    if self.isRunning && hasUploadableQueue {
                        // Refill one free small-file upload slot even if
                        // the other concurrent HEIC is still transferring.
                        self.startWebDAV(retryFailed: false)
                    } else if !hasUploadableQueue &&
                              !self.tasks.contains(where: {
                                  $0.state == .uploading
                              }) &&
                              self.unresolvedShareNamesCount > 0 {
                        // Do not display "传输中" forever when only
                        // unnamed, deliberately unscheduled Photos remain.
                        self.isRunning = false
                        self.statusMessage =
                            "其他文件已完成；还有 \(self.unresolvedShareNamesCount) 项" +
                            "待确认文件名"
                    }
                    await self.finishWebDAVBatchIfPossible()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .fileMannWebDAVFailed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let taskID = note.userInfo?["taskID"] as? UUID,
                      let message = note.userInfo?["message"] as? String else {
                    return
                }

                Task { @MainActor in
                    guard let self,
                          let index = self.tasks.firstIndex(where: { $0.id == taskID }) else {
                        return
                    }

                    self.tasks[index].state = .failed
                    self.tasks[index].errorMessage = "后台上传失败：\(message)"
                    self.lastProgressUIUpdate.removeValue(forKey: taskID)
                    self.persistTasks()
                    WebDAVBackgroundReceiptStore.remove(taskID: taskID)

                    if !self.tasks.contains(where: { $0.state == .uploading }) {
                        self.isRunning = false
                    }
                    self.statusMessage = "有后台上传失败，点“继续归档”重试"
                }
            }
        )
    }

    /// Reconcile durable verified results before inspecting URLSession
    /// tasks. Background callbacks can arrive before SwiftUI observers are
    /// installed, or the process may be suspended between a NAS MOVE and
    /// updating the task store.
    private func applyBackgroundReceipts() {
        for receipt in WebDAVBackgroundReceiptStore.load() {
            guard let index = tasks.firstIndex(where: {
                $0.id == receipt.taskID
            }) else {
                WebDAVBackgroundReceiptStore.remove(
                    taskID: receipt.taskID
                )
                continue
            }

            switch receipt.outcome {
            case .verified:
                guard let endpoint = receipt.endpoint,
                      let remotePath = receipt.remotePath,
                      let bytes = receipt.remoteSize,
                      bytes == tasks[index].fileSize,
                      endpoint == tasks[index].remoteEndpointURL,
                      remotePath == tasks[index].attemptedRemotePath else {
                    // Do not reuse a stale receipt after a rename, changed
                    // endpoint or newly queued transfer under the same ID.
                    WebDAVBackgroundReceiptStore.remove(
                        taskID: receipt.taskID
                    )
                    continue
                }
                tasks[index].transferredBytes = bytes
                tasks[index].remoteVerifiedPath = remotePath
                tasks[index].remoteEndpointURL = endpoint
                tasks[index].verifiedAt = receipt.recordedAt
                tasks[index].completionKind = .uploaded
                tasks[index].state = .completed
                tasks[index].errorMessage =
                    "后台归档完成：已恢复 NAS 严格落盘校验结果"
                cleanupShareStaging(at: index)

            case .failed:
                if tasks[index].state != .completed {
                    tasks[index].state = .failed
                    tasks[index].errorMessage =
                        "后台传输中断：" +
                        (receipt.message ?? "请检查网络后重试")
                }
            }

            // Never drop the journal before the task store was updated.
            persistTasks()
            WebDAVBackgroundReceiptStore.remove(
                taskID: receipt.taskID
            )
        }
    }

    /// A background upload may have written a complete .partial object (or
    /// the final direct-PUT target) when iOS stopped the app before the
    /// async MOVE/PROPFIND receipt could be persisted. Re-verify only the
    /// *recorded original endpoint* and own unique partial path before any
    /// new upload; never infer success from an unrelated NAS share.
    private func recoverInterruptedPublishedFiles() async {
        let active = await WebDAVBackgroundUploadManager.shared.activeTaskIDs()
        let snapshots = tasks.filter {
            ($0.state == .paused || $0.state == .queued ||
             $0.state == .failed) &&
            !active.contains($0.id) &&
            !$0.needsShareFilenameDecision &&
            $0.verifiedAt == nil &&
            $0.remoteEndpointURL != nil &&
            $0.attemptedRemotePath != nil
        }
        guard !snapshots.isEmpty else { return }

        var recovered = 0
        for snapshot in snapshots {
            guard let endpoint = snapshot.remoteEndpointURL,
                  let finalPath = snapshot.attemptedRemotePath,
                  let index = tasks.firstIndex(where: {
                      $0.id == snapshot.id
                  }) else { continue }

            do {
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: webDAVPassword,
                    baseURLString: endpoint
                )
                let result: ArchiveResult
                if let direct = try? await service.verifyPublishedFile(
                    at: finalPath,
                    expectedBytes: snapshot.fileSize
                ) {
                    result = direct
                } else {
                    let partialPath = finalPath + ".filemann-" +
                        snapshot.id.uuidString.lowercased() + ".partial"
                    // An incomplete partial MUST NOT be treated as done.
                    guard (try? await service.verifyPublishedFile(
                        at: partialPath,
                        expectedBytes: snapshot.fileSize
                    )) != nil else { continue }
                    result = try await service.finalizeBackgroundUpload(
                        partialPath: partialPath,
                        finalPath: finalPath,
                        expectedBytes: snapshot.fileSize,
                        uploadMode: .atomicMove
                    )
                }

                guard index < tasks.count,
                      tasks[index].id == snapshot.id,
                      tasks[index].remoteEndpointURL == endpoint,
                      tasks[index].attemptedRemotePath == finalPath else {
                    continue
                }
                tasks[index].state = .completed
                tasks[index].transferredBytes = result.remoteSize
                tasks[index].remoteVerifiedPath = result.remotePath
                tasks[index].verifiedAt = Date()
                tasks[index].completionKind = .uploaded
                tasks[index].errorMessage =
                    "从之前的后台传输恢复，已重新核实实际 NAS 路径"
                cleanupShareStaging(at: index)
                persistTasks()
                recovered += 1
            } catch {
                // Keep the original task retryable. Do not count an
                // unverified partial or a different endpoint as success.
                continue
            }
        }

        if recovered > 0 {
            invalidateVerification()
            statusMessage =
                "已从中断的后台传输恢复 \(recovered) 项，" +
                "均通过原上传端点的文件路径和大小校验"
        }
    }

    /// Called only while the app is visible to the user. iOS controls when
    /// it runs background tasks, so simply reopening FileMann may safely
    /// restore a user-started queue, but an explicit Pause stays respected.
    func resumeOnForegroundIfNeeded() {
        guard !isRecoveringOnForeground else { return }
        isRecoveringOnForeground = true

        Task { @MainActor in
            defer { isRecoveringOnForeground = false }
            await restoreWebDAVBackgroundTasks()

            guard TaskStore.shouldResumeArchive(), !isRunning,
                  unresolvedDuplicateCount == 0 else {
                return
            }

            await recoverInterruptedPublishedFiles()

            let hasPending = tasks.contains { task in
                (task.state == .queued || task.state == .paused) &&
                !task.needsShareFilenameDecision
            }
            guard hasPending else { return }

            for index in tasks.indices where tasks[index].state == .paused {
                tasks[index].state = .queued
                tasks[index].errorMessage =
                    "从上次系统后台中断后继续排队"
            }
            persistTasks()
            startWebDAV(retryFailed: false)
        }
    }

    private func restoreWebDAVBackgroundTasks() async {
        guard settings.transport == .webDAV else { return }

        // Creating the same background session identifier is required even
        // on a cold start with no visible UIKit scene.
        WebDAVBackgroundUploadManager.shared.reconnectBackgroundSession()
        applyBackgroundReceipts()

        let active = await WebDAVBackgroundUploadManager.shared.activeTaskIDs()
        applyBackgroundReceipts()
        let matching = Set(tasks.filter { active.contains($0.id) }.map(\.id))
        guard !matching.isEmpty else { return }

        let userStillWantsTransfer = TaskStore.shouldResumeArchive()
        for index in tasks.indices where matching.contains(tasks[index].id) {
            if tasks[index].state != .completed {
                tasks[index].state = userStillWantsTransfer
                    ? .uploading : .paused
                tasks[index].errorMessage = userStillWantsTransfer
                    ? "iOS 后台上传任务已恢复"
                    : "已暂停，等待用户手动继续"
            }
        }
        isRunning = userStillWantsTransfer &&
            tasks.contains(where: { $0.state == .uploading })
        persistTasks()
    }

    private func finishWebDAVBatchIfPossible() async {
        guard settings.transport == .webDAV else { return }

        if tasks.contains(where: {
            $0.state == .uploading ||
            $0.state == .queued ||
            $0.state == .paused
        }) {
            return
        }

        isRunning = false
        resetWebDAVBatchCache()
        TaskStore.setShouldResumeArchive(false)

        if tasks.contains(where: {
            $0.state == .failed || $0.state == .missingSource
        }) {
            statusMessage = "部分文件未完成，未执行整批删除"
            return
        }

        do {
            let verification = await verifyRecordedWebDAVManifest()
            lastVerification = verification
            TaskStore.saveVerification(verification)

            guard verification.passed else {
                statusMessage =
                    "WebDAV 整批校验失败：清单 \(verification.expectedCount) 个 / " +
                    "\(ByteFormat.string(verification.expectedBytes))，NAS 已确认 " +
                    "\(verification.verifiedCount) 个 / " +
                    "\(ByteFormat.string(verification.verifiedBytes))。未删除手机源文件。"
                return
            }

            if settings.deleteAfterArchive ||
                tasks.contains(where: {
                    $0.isShareStaging == true && !$0.sourceDeleted
                }) {
                // Used only to safely clean local sources after a
                // per-endpoint remote manifest check has passed.
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: webDAVPassword
                )
                var deletionFailures = 0

                for index in tasks.indices {
                    guard tasks[index].state == .completed,
                          !tasks[index].sourceDeleted,
                          (tasks[index].isShareStaging == true ||
                            (settings.deleteAfterArchive &&
                             tasks[index].shouldDeleteSource != false)) else {
                        continue
                    }

                    do {
                        let sourceURL = try resolveBookmark(tasks[index].bookmark)
                        try service.deleteSourceFile(at: sourceURL)
                        tasks[index].sourceDeleted = true
                    } catch {
                        deletionFailures += 1
                        tasks[index].errorMessage =
                            "NAS 整批校验已通过，但本地文件删除失败：\(error.localizedDescription)"
                    }

                    persistTasks()
                }

                if deletionFailures == 0 {
                    statusMessage =
                        "后台归档完成并通过整批校验：\(verification.verifiedCount) 个 / " +
                        "\(ByteFormat.string(verification.verifiedBytes))。本地副本已按设置删除。"
                } else {
                    statusMessage =
                        "后台归档与整批校验通过，但有 \(deletionFailures) 个本地文件删除失败。"
                }
            } else {
                statusMessage =
                    "后台归档完成并通过整批校验：\(verification.verifiedCount) 个 / " +
                    "\(ByteFormat.string(verification.verifiedBytes))。本地副本已保留。"
            }
        } catch {
            statusMessage = "WebDAV 整批校验失败：\(error.localizedDescription)"
        }
    }

    private func runQueue() async {
        defer {
            isRunning = false
            worker = nil
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            persistTasks()
        }

        do {
            let service = try SMBArchiveService(settings: settings, password: password)
            try await service.connectAndPrepare()

            let foundNewDuplicates = try await scanForDuplicates(using: service)
            if foundNewDuplicates || unresolvedDuplicateCount > 0 {
                isShowingDuplicateReview = true
                statusMessage = "发现 \(unresolvedDuplicateCount) 个内容完全相同的文件，请先选择保留方式"
                return
            }

            try await applyResolvedDuplicates(using: service)

            let ids = tasks
                .filter { $0.state != .completed && $0.state != .skipped }
                .map(\.id)

            for id in ids {
                try Task.checkCancellation()
                guard let index = tasks.firstIndex(where: { $0.id == id }) else { continue }

                tasks[index].state = .uploading
                tasks[index].errorMessage = nil
                persistTasks()

                let taskSnapshot = tasks[index]

                do {
                    let sourceURL = try resolveBookmark(taskSnapshot.bookmark)

                    let result = try await service.archive(
                        task: taskSnapshot,
                        sourceURL: sourceURL,
                        progress: { [weak self] bytes in
                            Task { @MainActor in
                                self?.updateProgress(id: id, bytes: bytes)
                            }
                        }
                    )

                    guard let current = tasks.firstIndex(where: { $0.id == id }) else { continue }
                    tasks[current].transferredBytes = result.remoteSize
                    tasks[current].remoteVerifiedPath = result.remotePath
                    tasks[current].state = .completed
                    cleanupShareStaging(at: current)
                    persistTasks()
                } catch is CancellationError {
                    if let current = tasks.firstIndex(where: { $0.id == id }) {
                        tasks[current].state = .paused
                    }
                    persistTasks()
                    return
                } catch {
                    guard let current = tasks.firstIndex(where: { $0.id == id }) else { continue }
                    tasks[current].state = isSourceAccessError(error) ? .missingSource : .failed
                    tasks[current].errorMessage = error.localizedDescription
                    persistTasks()
                }
            }

            let verification = await service.verifyManifest(tasks)
            lastVerification = verification
            TaskStore.saveVerification(verification)

            guard verification.passed else {
                statusMessage = "整批校验失败：手机清单 \(verification.expectedCount) 个 / \(ByteFormat.string(verification.expectedBytes))，NAS 已确认 \(verification.verifiedCount) 个 / \(ByteFormat.string(verification.verifiedBytes))。未删除任何手机源文件。"
                return
            }

            if settings.deleteAfterArchive ||
                tasks.contains(where: {
                    $0.isShareStaging == true && !$0.sourceDeleted
                }) {
                var deletionFailures = 0
                for index in tasks.indices {
                    guard tasks[index].state == .completed,
                          !tasks[index].sourceDeleted,
                          (tasks[index].isShareStaging == true ||
                            (settings.deleteAfterArchive &&
                             tasks[index].shouldDeleteSource != false)) else {
                        continue
                    }

                    do {
                        let sourceURL = try resolveBookmark(tasks[index].bookmark)
                        try service.deleteSourceFile(at: sourceURL)
                        tasks[index].sourceDeleted = true
                    } catch {
                        deletionFailures += 1
                        tasks[index].errorMessage = "NAS 整批校验已通过，但源文件删除失败：\(error.localizedDescription)"
                    }
                    persistTasks()
                }

                if deletionFailures == 0 {
                    statusMessage = "整批校验通过：\(verification.verifiedCount) 个 / \(ByteFormat.string(verification.verifiedBytes))。手机源文件已按设置删除。"
                } else {
                    statusMessage = "整批校验通过，但有 \(deletionFailures) 个手机源文件删除失败。"
                }
            } else {
                statusMessage = "整批校验通过：\(verification.verifiedCount) 个 / \(ByteFormat.string(verification.verifiedBytes))。手机源文件已保留。"
            }
        } catch is CancellationError {
            statusMessage = "已暂停"
        } catch {
            statusMessage = "SMB 处理失败：\(error.localizedDescription)"
        }
    }

    private func scanForDuplicates(using service: SMBArchiveService) async throws -> Bool {
        let knownTaskIDs = Set(duplicateCandidates.map(\.taskID))
        let candidates = tasks.filter {
            $0.state != .completed &&
            $0.state != .skipped &&
            !knownTaskIDs.contains($0.id)
        }

        guard !candidates.isEmpty else { return false }

        var found = false
        for (offset, task) in candidates.enumerated() {
            try Task.checkCancellation()
            statusMessage = "正在检查重复文件 \(offset + 1)/\(candidates.count)：\(task.displayName)"

            do {
                let sourceURL = try resolveBookmark(task.bookmark)
                if let remote = try await service.findExactDuplicate(task: task, sourceURL: sourceURL) {
                    duplicateCandidates.append(
                        DuplicateCandidate(
                            taskID: task.id,
                            remotePath: remote.path,
                            remoteName: remote.name,
                            fileSize: remote.size
                        )
                    )
                    found = true
                    persistDuplicates()
                }
            } catch ArchiveServiceError.sourceUnavailable {
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].state = .missingSource
                    tasks[index].errorMessage = ArchiveServiceError.sourceUnavailable.localizedDescription
                }
            }
        }

        return found
    }

    private func applyResolvedDuplicates(using service: SMBArchiveService) async throws {
        for candidate in duplicateCandidates where candidate.decision != .unresolved {
            guard let index = tasks.firstIndex(where: { $0.id == candidate.taskID }),
                  tasks[index].state != .completed,
                  tasks[index].state != .skipped else {
                continue
            }

            switch candidate.decision {
            case .unresolved:
                break

            case .keepNAS:
                tasks[index].state = .completed
                tasks[index].transferredBytes = tasks[index].fileSize
                tasks[index].remoteVerifiedPath = candidate.remotePath
                tasks[index].shouldDeleteSource = true
                tasks[index].errorMessage = "重复文件：使用 NAS 已有副本，整批校验后删除手机副本"

            case .keepPhone:
                try await service.deleteRemoteFile(at: candidate.remotePath)
                tasks[index].state = .skipped
                tasks[index].transferredBytes = 0
                tasks[index].shouldDeleteSource = false
                tasks[index].errorMessage = "重复文件：已删除 NAS 副本，仅保留手机文件"

            case .keepBoth:
                tasks[index].state = .completed
                tasks[index].transferredBytes = tasks[index].fileSize
                tasks[index].remoteVerifiedPath = candidate.remotePath
                tasks[index].shouldDeleteSource = false
                tasks[index].errorMessage = "重复文件：两边都保留，不重复上传"
            }
            persistTasks()
        }
    }

    private func resolveBookmark(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        if stale {
            statusMessage = "部分文件/位置授权已过期，如访问失败请重新选择"
        }
        return url
    }

    private func updateProgress(id: UUID, bytes: Int64) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(speedSampleDate)
        let displayedElapsed = now.timeIntervalSince(
            lastProgressUIUpdate[id] ?? .distantPast
        )
        // Coalesce bursts of URLSession progress callbacks; keep the final
        // 100% event and the per-second throughput sample visible.
        if bytes < tasks[index].fileSize &&
            displayedElapsed < 0.25 && elapsed < 1 {
            return
        }

        tasks[index].transferredBytes = min(bytes, tasks[index].fileSize)
        lastProgressUIUpdate[id] = now
        if elapsed >= 1 {
            let currentTotal = transferredBytes
            bytesPerSecond = max(
                0, Double(currentTotal - speedSampleBytes) / elapsed
            )
            speedSampleDate = now
            speedSampleBytes = currentTotal
            persistTasks()
        }
    }

    private func uniqueRemoteName(for original: String) -> String {
        let existing = Set(tasks.map { $0.remoteFileName.lowercased() })
        guard existing.contains(original.lowercased()) else { return original }
        var counter = 2
        while true {
            let candidate = FileMannShareFileNaming.addingDuplicateSuffix(
                to: original, number: counter
            )
            if !existing.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    private func makeReachableWebDAVService(
        forceRemote: Bool = false
    ) async throws -> WebDAVArchiveService {
        let resolved = try await WebDAVArchiveService.resolveBestBaseURL(
            settings: settings,
            password: webDAVPassword,
            forceRemote: forceRemote
        )

        let service = try WebDAVArchiveService(
            settings: settings,
            password: webDAVPassword,
            baseURLString: resolved
        )
        let endpoint = URL(string: service.baseURLString)
        let port = endpoint?.port.map { ":\($0)" } ?? ""
        activeWebDAVEndpoint =
            "\(service.endpointLabel) · \(endpoint?.host ?? "NAS")\(port)"
        return service
    }

    // Share-sheet staging is disposable, unlike the Photos original.
    // Clean it immediately after the NAS file is verified, even when a
    // different task in the batch later fails. Never delete arbitrary paths.
    private func cleanupShareStaging(at index: Int) {
        guard tasks.indices.contains(index),
              tasks[index].isShareStaging == true,
              tasks[index].state == .completed,
              !tasks[index].sourceDeleted,
              let inbox = try? FileMannShareGroup.incomingDirectory(
                createIfMissing: false
              ),
              let url = try? resolveBookmark(tasks[index].bookmark)
        else { return }
        guard url.deletingLastPathComponent().standardizedFileURL ==
                inbox.standardizedFileURL else {
            return
        }

        do {
            try FileMannShareFileNaming.discardStagedFile(url)
            tasks[index].sourceDeleted = true
            tasks[index].errorMessage =
                "已验证归档；分享暂存文件已清理，相册原件不受影响"
        } catch {
            tasks[index].errorMessage =
                "已验证归档；分享暂存清理失败：\(error.localizedDescription)"
        }
    }

    private func isSourceAccessError(_ error: Error) -> Bool {
        if let value = error as? ArchiveServiceError,
           case .sourceUnavailable = value {
            return true
        }
        if let value = error as? WebDAVArchiveError,
           case .sourceUnavailable = value {
            return true
        }
        return false
    }

    private func invalidateVerification() {
        lastVerification = nil
        TaskStore.saveVerification(nil)
    }

    private func persistTasks() {
        TaskStore.saveTasks(tasks)
    }

    private func persistLocations() {
        TaskStore.saveLocations(sourceLocations)
    }

    private func persistDuplicates() {
        TaskStore.saveDuplicates(duplicateCandidates)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FileMann archive") { [weak self] in
            Task { @MainActor in
                self?.pause()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private nonisolated static func scanLocationFiles(_ location: SourceLocation) throws -> (tasks: [ArchiveTask], fileCount: Int, totalBytes: Int64) {
        var stale = false
        let folderURL = try URL(
            resolvingBookmarkData: location.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart || FileManager.default.isReadableFile(atPath: folderURL.path) else {
            throw ArchiveServiceError.sourceUnavailable
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .nameKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ArchiveServiceError.sourceUnavailable
        }

        let basePath = folderURL.standardizedFileURL.path
        var result: [ArchiveTask] = []
        var totalBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }

            let standardizedPath = fileURL.standardizedFileURL.path
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            let relativePath: String
            if standardizedPath.hasPrefix(prefix) {
                relativePath = String(standardizedPath.dropFirst(prefix.count))
            } else {
                relativePath = fileURL.lastPathComponent
            }

            let bookmark = try fileURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let size = Int64(values.fileSize ?? 0)
            let name = values.name ?? fileURL.lastPathComponent

            result.append(
                ArchiveTask(
                    bookmark: bookmark,
                    displayName: name,
                    remoteFileName: name,
                    remoteRelativePath: relativePath,
                    sourceLocationID: location.id,
                    sourceRelativePath: relativePath,
                    fileSize: size,
                    sourceModifiedAt: values.contentModificationDate
                )
            )
            totalBytes += size
        }

        return (result, result.count, totalBytes)
    }
}
