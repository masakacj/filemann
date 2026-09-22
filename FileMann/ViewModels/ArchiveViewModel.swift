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

    @Published var isRunning = false
    @Published var isScanningLocation = false
    @Published var isShowingFilePicker = false
    @Published var isShowingFolderPicker = false
    @Published var isShowingSettings = false
    @Published var isShowingDuplicateReview = false
    @Published var statusMessage: String?
    @Published var connectionTestMessage: String?
    @Published var bytesPerSecond: Double = 0

    private var worker: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var speedSampleDate = Date()
    private var speedSampleBytes: Int64 = 0

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

        let validTaskIDs = Set(tasks.map(\.id))
        self.duplicateCandidates.removeAll { !validTaskIDs.contains($0.taskID) }
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
        tasks.filter { $0.state == .completed }.count
    }

    var unresolvedDuplicateCount: Int {
        duplicateCandidates.filter { $0.decision == .unresolved }.count
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
        TaskStore.saveSettings(settings)
        do {
            try KeychainStore.savePassword(password)
            statusMessage = "SMB 设置已保存"
        } catch {
            statusMessage = "密码保存失败：\(error.localizedDescription)"
        }
    }

    func chooseRemoteDirectory(_ path: String) {
        settings.remoteDirectory = path
        saveSettings()
    }

    func loadRemoteDirectories(at path: String) async throws -> [SMBDirectoryEntry] {
        let service = try SMBArchiveService(settings: settings, password: password)
        return try await service.listDirectories(at: path)
    }

    func testConnection() {
        connectionTestMessage = "连接中…"
        Task {
            do {
                let service = try SMBArchiveService(settings: settings, password: password)
                try await service.testConnection()
                connectionTestMessage = "连接成功"
            } catch {
                connectionTestMessage = "连接失败：\(error.localizedDescription)"
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
        guard settings.isValid else {
            statusMessage = "请先配置 SMB 服务器和共享名"
            isShowingSettings = true
            return
        }

        if unresolvedDuplicateCount > 0 {
            isShowingDuplicateReview = true
            statusMessage = "请先处理 \(unresolvedDuplicateCount) 个重复文件"
            return
        }

        saveSettings()

        for index in tasks.indices {
            if tasks[index].state == .failed || tasks[index].state == .paused || tasks[index].state == .missingSource {
                tasks[index].state = .queued
                tasks[index].errorMessage = nil
            }
        }
        persistTasks()

        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        beginBackgroundTask()

        speedSampleDate = Date()
        speedSampleBytes = transferredBytes
        bytesPerSecond = 0

        worker = Task { [weak self] in
            await self?.runQueue()
        }
    }

    func pause() {
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
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].state = .queued
        tasks[index].errorMessage = nil
        persistTasks()
    }

    func removeTask(_ task: ArchiveTask) {
        tasks.removeAll { $0.id == task.id }
        duplicateCandidates.removeAll { $0.taskID == task.id }
        invalidateVerification()
        persistTasks()
        persistDuplicates()
    }

    func clearCompleted() {
        let removedIDs = Set(tasks.filter { $0.state == .completed || $0.state == .skipped }.map(\.id))
        tasks.removeAll { removedIDs.contains($0.id) }
        duplicateCandidates.removeAll { removedIDs.contains($0.taskID) }
        persistTasks()
        persistDuplicates()
    }

    func task(for candidate: DuplicateCandidate) -> ArchiveTask? {
        tasks.first { $0.id == candidate.taskID }
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

            if settings.deleteAfterArchive {
                var deletionFailures = 0
                for index in tasks.indices {
                    guard tasks[index].state == .completed,
                          !tasks[index].sourceDeleted,
                          tasks[index].shouldDeleteSource != false else {
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
        tasks[index].transferredBytes = min(bytes, tasks[index].fileSize)

        let now = Date()
        let elapsed = now.timeIntervalSince(speedSampleDate)
        if elapsed >= 1 {
            let currentTotal = transferredBytes
            bytesPerSecond = max(0, Double(currentTotal - speedSampleBytes) / elapsed)
            speedSampleDate = now
            speedSampleBytes = currentTotal
            persistTasks()
        }
    }

    private func uniqueRemoteName(for original: String) -> String {
        let existing = Set(tasks.map { $0.remoteFileName.lowercased() })
        guard existing.contains(original.lowercased()) else { return original }

        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }

    private func isSourceAccessError(_ error: Error) -> Bool {
        if let value = error as? ArchiveServiceError,
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
