import Foundation

/// Diagnostics and conservative cleanup for this app's own tmp directory.
/// This does NOT include the App Group, NAS, Photos library, document inbox
/// or Apple-managed Library/Caches. Live URLSession tasks are checked by the
/// caller before any deletion is allowed.
struct FileMannTemporaryFile: Identifiable, Equatable, Sendable {
    var path: String
    var bytes: Int64
    var modifiedAt: Date
    var id: String { path }
}

struct FileMannTemporaryScan: Equatable, Sendable {
    var totalBytes: Int64
    var fileCount: Int
    var reclaimableBytes: Int64
    var reclaimableCount: Int
    var largestFiles: [FileMannTemporaryFile]
}

struct FileMannTemporaryCleanupResult: Equatable, Sendable {
    var removedCount: Int
    var removedBytes: Int64
    var failedCount: Int
}

enum FileMannTemporaryStorage {
    // Protect files just created by the system, picker or a media viewer.
    static let minimumAge: TimeInterval = 10 * 60

    private struct Candidate {
        let url: URL
        let bytes: Int64
        let modifiedAt: Date
    }

    static func inspect(
        under root: URL = FileManager.default.temporaryDirectory,
        at now: Date = Date()
    ) -> FileMannTemporaryScan {
        let entries = candidates(under: root)
        let threshold = now.addingTimeInterval(-minimumAge)
        let eligible = entries.filter { $0.modifiedAt < threshold }
        let rootPath = root.standardizedFileURL.path
        let largest = entries.sorted { $0.bytes > $1.bytes }
            .prefix(8).map { entry in
                let path = entry.url.standardizedFileURL.path
                let prefix = rootPath.hasSuffix("/")
                    ? rootPath : rootPath + "/"
                return FileMannTemporaryFile(
                    path: path.hasPrefix(prefix)
                        ? String(path.dropFirst(prefix.count))
                        : entry.url.lastPathComponent,
                    bytes: entry.bytes,
                    modifiedAt: entry.modifiedAt
                )
            }
        return FileMannTemporaryScan(
            totalBytes: entries.reduce(0) { $0 + $1.bytes },
            fileCount: entries.count,
            reclaimableBytes: eligible.reduce(0) { $0 + $1.bytes },
            reclaimableCount: eligible.count,
            largestFiles: largest
        )
    }

    /// Call ONLY after the archive queue is empty and URLSession has no
    /// registered/finishing task. Recheck age just before unlinking: a file
    /// touched since the preview must not be removed.
    static func removeStaleFiles(
        under root: URL = FileManager.default.temporaryDirectory,
        at now: Date = Date()
    ) -> FileMannTemporaryCleanupResult {
        let fileManager = FileManager.default
        let cutoff = now.addingTimeInterval(-minimumAge)
        var removedBytes: Int64 = 0
        var removedCount = 0
        var failedCount = 0

        for candidate in candidates(under: root) {
            guard candidate.modifiedAt < cutoff,
                  let attributes = try? candidate.url.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                        .contentModificationDateKey
                    ]
                  ),
                  attributes.isRegularFile == true,
                  attributes.isSymbolicLink != true,
                  let modified = attributes.contentModificationDate,
                  modified < cutoff else {
                continue
            }

            do {
                try fileManager.removeItem(at: candidate.url)
                removedBytes += candidate.bytes
                removedCount += 1
            } catch {
                failedCount += 1
            }
        }
        return FileMannTemporaryCleanupResult(
            removedCount: removedCount,
            removedBytes: removedBytes,
            failedCount: failedCount
        )
    }

    private static func candidates(under root: URL) -> [Candidate] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                .fileSizeKey
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var result: [Candidate] = []
        for case let file as URL in walker {
            guard let properties = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                .fileSizeKey
            ]), properties.isRegularFile == true,
               properties.isSymbolicLink != true,
               let modified = properties.contentModificationDate else {
                continue
            }
            result.append(Candidate(
                url: file,
                bytes: Int64(max(0,
                    properties.totalFileAllocatedSize ??
                    properties.fileAllocatedSize ??
                    properties.fileSize ?? 0
                )),
                modifiedAt: modified
            ))
        }
        return result
    }
}
