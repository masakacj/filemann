import AMSMB2
import Foundation

enum ArchiveServiceError: LocalizedError {
    case invalidServer
    case sourceUnavailable
    case sourceChanged
    case remoteConflict(String)
    case remoteVerificationFailed
    case emptyRead

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "SMB 服务器地址无效"
        case .sourceUnavailable:
            return "无法访问源文件，请重新选择"
        case .sourceChanged:
            return "源文件已发生变化，请重新加入任务"
        case .remoteConflict(let name):
            return "NAS 上已存在同路径但内容不同的文件：\(name)"
        case .remoteVerificationFailed:
            return "NAS 文件大小校验失败"
        case .emptyRead:
            return "读取源文件时提前结束"
        }
    }
}

struct ArchiveResult {
    let remoteSize: Int64
    let remotePath: String
}

struct RemoteFileInfo: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
}

struct SMBDirectoryEntry: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
}

final class SMBArchiveService {
    private let settings: SMBSettings
    private let password: String
    private let manager: SMB2Manager
    private var inventoryCache: [RemoteFileInfo]?

    init(settings: SMBSettings, password: String) throws {
        self.settings = settings
        self.password = password

        guard let url = URL(string: "smb://\(settings.normalizedHost)"),
              let client = SMB2Manager(
                url: url,
                credential: URLCredential(
                    user: settings.username,
                    password: password,
                    persistence: .forSession
                )
              ) else {
            throw ArchiveServiceError.invalidServer
        }

        client.timeout = 60
        self.manager = client
    }

    func connectAndPrepare() async throws {
        try await manager.connectShare(name: settings.normalizedShare)
        try await ensureRemoteDirectory()
    }

    func testConnection() async throws {
        try await connectAndPrepare()
        let path = settings.normalizedDirectory.isEmpty ? "/" : settings.normalizedDirectory
        _ = try await manager.contentsOfDirectory(atPath: path)
    }

    func listDirectories(at path: String) async throws -> [SMBDirectoryEntry] {
        try await manager.connectShare(name: settings.normalizedShare)
        let queryPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let attributes = try await manager.contentsOfDirectory(atPath: queryPath.isEmpty ? "/" : queryPath)
        return attributes.compactMap { item in
            guard item.isDirectory,
                  let name = item.name,
                  name != ".",
                  name != ".." else {
                return nil
            }
            let fullPath = join(queryPath, name)
            return SMBDirectoryEntry(path: fullPath, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func archive(
        task: ArchiveTask,
        sourceURL: URL,
        progress: @escaping (Int64) -> Void
    ) async throws -> ArchiveResult {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart || FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ArchiveServiceError.sourceUnavailable
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let currentSize = Int64(values.fileSize ?? 0)
        guard currentSize == task.fileSize else {
            throw ArchiveServiceError.sourceChanged
        }

        if let originalModified = task.sourceModifiedAt,
           let currentModified = values.contentModificationDate,
           abs(currentModified.timeIntervalSince(originalModified)) > 1 {
            throw ArchiveServiceError.sourceChanged
        }

        let finalPath = remotePath(for: task)
        try await ensureParentDirectory(for: finalPath)
        let partialPath = finalPath + ".filemann-partial"

        if let existingFinal = await remoteFileSize(atPath: finalPath) {
            guard existingFinal == task.fileSize else {
                throw ArchiveServiceError.remoteConflict(task.displayName)
            }
            let same = try await exactCompare(
                sourceURL: sourceURL,
                remotePath: finalPath,
                size: task.fileSize,
                sourceAlreadyScoped: true
            )
            guard same else {
                throw ArchiveServiceError.remoteConflict(task.displayName)
            }
            progress(task.fileSize)
            return ArchiveResult(remoteSize: existingFinal, remotePath: finalPath)
        }

        var offset = await remoteFileSize(atPath: partialPath) ?? 0

        if offset > task.fileSize {
            try? await manager.removeFile(atPath: partialPath)
            offset = 0
        }

        progress(offset)

        let chunkBytes = max(1, settings.chunkSizeMB) * 1024 * 1024

        while offset < task.fileSize {
            try Task.checkCancellation()

            let remaining = task.fileSize - offset
            let count = Int(min(Int64(chunkBytes), remaining))
            let chunk = try readChunk(
                from: sourceURL,
                offset: UInt64(offset),
                count: count
            )

            guard !chunk.isEmpty else {
                throw ArchiveServiceError.emptyRead
            }

            let chunkStart = offset
            try await manager.append(
                data: chunk,
                toPath: partialPath,
                offset: chunkStart,
                progress: { _ in
                    !Task.isCancelled
                }
            )

            offset += Int64(chunk.count)
            progress(offset)
        }

        guard await remoteFileSize(atPath: partialPath) == task.fileSize else {
            throw ArchiveServiceError.remoteVerificationFailed
        }

        try await manager.moveItem(atPath: partialPath, toPath: finalPath)

        guard await remoteFileSize(atPath: finalPath) == task.fileSize else {
            throw ArchiveServiceError.remoteVerificationFailed
        }

        inventoryCache = nil
        progress(task.fileSize)
        return ArchiveResult(remoteSize: task.fileSize, remotePath: finalPath)
    }

    func findExactDuplicate(task: ArchiveTask, sourceURL: URL) async throws -> RemoteFileInfo? {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart || FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ArchiveServiceError.sourceUnavailable
        }

        let candidates = try await remoteInventory().filter { $0.size == task.fileSize }
        guard !candidates.isEmpty else { return nil }

        for candidate in candidates {
            try Task.checkCancellation()
            if try await exactCompare(
                sourceURL: sourceURL,
                remotePath: candidate.path,
                size: task.fileSize,
                sourceAlreadyScoped: true
            ) {
                return candidate
            }
        }

        return nil
    }

    func verifyManifest(_ tasks: [ArchiveTask]) async -> BatchVerification {
        let expected = tasks.filter { $0.state != .skipped }
        let expectedCount = expected.count
        let expectedBytes = expected.reduce(Int64(0)) { $0 + $1.fileSize }

        var verifiedCount = 0
        var verifiedBytes: Int64 = 0

        for task in expected {
            let path = task.remoteVerifiedPath ?? remotePath(for: task)
            if let size = await remoteFileSize(atPath: path), size == task.fileSize {
                verifiedCount += 1
                verifiedBytes += size
            }
        }

        return BatchVerification(
            expectedCount: expectedCount,
            expectedBytes: expectedBytes,
            verifiedCount: verifiedCount,
            verifiedBytes: verifiedBytes,
            checkedAt: Date()
        )
    }

    func deleteRemoteFile(at path: String) async throws {
        try await manager.removeFile(atPath: path)
        inventoryCache = nil
    }

    func deleteSourceFile(at url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard didStart || FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveServiceError.sourceUnavailable
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deletionError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                deletionError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let deletionError {
            throw deletionError
        }
    }

    func desiredRemotePath(for task: ArchiveTask) -> String {
        remotePath(for: task)
    }

    private func remoteInventory() async throws -> [RemoteFileInfo] {
        if let inventoryCache {
            return inventoryCache
        }

        let directory = settings.normalizedDirectory
        let queryPath = directory.isEmpty ? "/" : directory
        let attributes = try await manager.contentsOfDirectory(atPath: queryPath, recursive: true)
        let files = attributes.compactMap { item -> RemoteFileInfo? in
            guard item.isRegularFile,
                  let path = item.path,
                  let name = item.name,
                  let size = item.fileSize,
                  !name.hasSuffix(".filemann-partial") else {
                return nil
            }
            return RemoteFileInfo(path: path, name: name, size: size)
        }
        inventoryCache = files
        return files
    }

    private func exactCompare(
        sourceURL: URL,
        remotePath: String,
        size: Int64,
        sourceAlreadyScoped: Bool
    ) async throws -> Bool {
        var didStart = false
        if !sourceAlreadyScoped {
            didStart = sourceURL.startAccessingSecurityScopedResource()
        }
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let compareChunk = 4 * 1024 * 1024
        var offset: Int64 = 0

        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(Int64(compareChunk), size - offset))
            let local = try readChunk(from: sourceURL, offset: UInt64(offset), count: count)
            let upper = offset + Int64(local.count)
            guard upper > offset else { return false }

            let remote = try await manager.contents(
                atPath: remotePath,
                range: UInt64(offset)..<UInt64(upper),
                progress: nil
            )

            if local != remote {
                return false
            }
            offset = upper
        }

        return true
    }

    private func readChunk(from url: URL, offset: UInt64, count: Int) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var result = Data()

        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: offset)
                result = try handle.read(upToCount: count) ?? Data()
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let readError {
            throw readError
        }
        return result
    }

    private func remotePath(for task: ArchiveTask) -> String {
        let relative = (task.remoteRelativePath?.isEmpty == false)
            ? task.remoteRelativePath!
            : task.remoteFileName
        return join(settings.normalizedDirectory, relative)
    }

    private func remoteFileSize(atPath path: String) async -> Int64? {
        do {
            let attrs = try await manager.attributesOfItem(atPath: path)
            if let n = attrs[.fileSizeKey] as? NSNumber {
                return n.int64Value
            }
            if let n = attrs[.fileSizeKey] as? Int64 {
                return n
            }
            if let n = attrs[.fileSizeKey] as? Int {
                return Int64(n)
            }
            return nil
        } catch {
            return nil
        }
    }

    private func ensureRemoteDirectory() async throws {
        try await ensureDirectory(settings.normalizedDirectory)
    }

    private func ensureParentDirectory(for filePath: String) async throws {
        let nsPath = filePath as NSString
        let parent = nsPath.deletingLastPathComponent
        try await ensureDirectory(parent)
    }

    private func ensureDirectory(_ directory: String) async throws {
        let normalized = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !normalized.isEmpty else { return }

        var current = ""
        for component in normalized.split(separator: "/").map(String.init) {
            current = current.isEmpty ? component : "\(current)/\(component)"
            do {
                _ = try await manager.attributesOfItem(atPath: current)
            } catch {
                do {
                    try await manager.createDirectory(atPath: current)
                } catch {
                    _ = try await manager.attributesOfItem(atPath: current)
                }
            }
        }
    }

    private func join(_ left: String, _ right: String) -> String {
        let l = left.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let r = right.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if l.isEmpty { return r }
        if r.isEmpty { return l }
        return "\(l)/\(r)"
    }
}
