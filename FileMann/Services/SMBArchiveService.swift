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
            return "NAS 上已存在同名但大小不同的文件：\(name)"
        case .remoteVerificationFailed:
            return "NAS 文件大小校验失败"
        case .emptyRead:
            return "读取源文件时提前结束"
        }
    }
}

struct ArchiveResult {
    let remoteSize: Int64
    let sourceDeleted: Bool
    let warning: String?
}

final class SMBArchiveService {
    private let settings: SMBSettings
    private let password: String
    private let manager: SMB2Manager

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
        let path = settings.normalizedDirectory
        _ = try await manager.contentsOfDirectory(atPath: path)
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

        let finalPath = remotePath(for: task.remoteFileName)
        let partialPath = finalPath + ".filemann-partial"

        if let existingFinal = await remoteFileSize(atPath: finalPath) {
            guard existingFinal == task.fileSize else {
                throw ArchiveServiceError.remoteConflict(task.remoteFileName)
            }
            progress(task.fileSize)
            return try finishSourceDeletionIfNeeded(sourceURL: sourceURL, remoteSize: existingFinal)
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
                progress: { written in
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

        progress(task.fileSize)
        return try finishSourceDeletionIfNeeded(sourceURL: sourceURL, remoteSize: task.fileSize)
    }

    private func finishSourceDeletionIfNeeded(sourceURL: URL, remoteSize: Int64) throws -> ArchiveResult {
        guard settings.deleteAfterArchive else {
            return ArchiveResult(remoteSize: remoteSize, sourceDeleted: false, warning: nil)
        }

        do {
            try deleteExternalFile(at: sourceURL)
            return ArchiveResult(remoteSize: remoteSize, sourceDeleted: true, warning: nil)
        } catch {
            return ArchiveResult(
                remoteSize: remoteSize,
                sourceDeleted: false,
                warning: "NAS 已归档成功，但删除手机源文件失败：\(error.localizedDescription)"
            )
        }
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

    private func deleteExternalFile(at url: URL) throws {
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

    private func remotePath(for fileName: String) -> String {
        let directory = settings.normalizedDirectory
        return directory.isEmpty ? fileName : "\(directory)/\(fileName)"
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
        let directory = settings.normalizedDirectory
        guard !directory.isEmpty else { return }

        var current = ""
        for component in directory.split(separator: "/").map(String.init) {
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
}
