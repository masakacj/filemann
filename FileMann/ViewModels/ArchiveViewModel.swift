import Foundation
import UIKit

@MainActor
final class ArchiveViewModel: ObservableObject {
    @Published var tasks: [ArchiveTask]
    @Published var settings: SMBSettings
    @Published var password: String
    @Published var isRunning = false
    @Published var isShowingPicker = false
    @Published var isShowingSettings = false
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
        self.settings = TaskStore.loadSettings()
        self.password = KeychainStore.loadPassword()
    }

    var totalBytes: Int64 {
        tasks.reduce(0) { $0 + $1.fileSize }
    }

    var transferredBytes: Int64 {
        tasks.reduce(0) { $0 + min($1.transferredBytes, $1.fileSize) }
    }

    var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    var completedCount: Int {
        tasks.filter { $0.state == .completed }.count
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

        persistTasks()

        if failures.isEmpty {
            statusMessage = "已加入 \(added) 个文件"
        } else {
            statusMessage = "加入 \(added) 个，失败 \(failures.count) 个\n" + failures.prefix(3).joined(separator: "\n")
        }
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

    func start() {
        guard !isRunning else { return }
        guard settings.isValid else {
            statusMessage = "请先配置 SMB 服务器和共享名"
            isShowingSettings = true
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
        persistTasks()
    }

    func clearCompleted() {
        tasks.removeAll { $0.state == .completed }
        persistTasks()
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

            let ids = tasks
                .filter { $0.state != .completed }
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
                    tasks[current].sourceDeleted = result.sourceDeleted
                    tasks[current].state = .completed
                    tasks[current].errorMessage = result.warning
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

            statusMessage = "归档队列处理完成"
        } catch is CancellationError {
            statusMessage = "已暂停"
        } catch {
            statusMessage = "SMB 连接失败：\(error.localizedDescription)"
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
            statusMessage = "部分文件授权已过期，如访问失败请重新选择文件"
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

    private func persistTasks() {
        TaskStore.saveTasks(tasks)
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
}
