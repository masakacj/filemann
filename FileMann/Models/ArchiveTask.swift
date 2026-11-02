import Foundation

enum ArchiveTaskState: String, Codable {
    case queued
    case uploading
    case paused
    case completed
    case skipped
    case failed
    case missingSource

    var title: String {
        switch self {
        case .queued: return "等待"
        case .uploading: return "上传中"
        case .paused: return "已暂停"
        case .completed: return "已归档"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .missingSource: return "源文件不可用"
        }
    }
}

enum ArchiveCompletionKind: String, Codable {
    case uploaded
    case alreadyOnNAS
}

struct ArchiveTask: Identifiable, Codable, Equatable {
    let id: UUID
    var bookmark: Data
    var displayName: String
    var remoteFileName: String
    var remoteRelativePath: String?
    var sourceLocationID: UUID?
    var sourceRelativePath: String?
    /// Disposable App Group share staging; never a Photos library original.
    var isShareStaging: Bool?
    var remoteVerifiedPath: String?
    /// Exact WebDAV base used by the upload, including its URL path prefix.
    /// Never infer this from a later local/WAN fallback.
    var remoteEndpointURL: String?
    /// Proposed file location, retained even when final verification fails.
    var attemptedRemotePath: String?
    /// Set only after the file appears in the actual parent's Depth:1 listing.
    var verifiedAt: Date?
    var completionKind: ArchiveCompletionKind?

    var remoteAbsoluteURL: String? {
        guard let endpoint = remoteEndpointURL,
              let base = URL(string: endpoint),
              let path = remoteVerifiedPath ?? attemptedRemotePath else {
            return nil
        }
        var url = base
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        return url.absoluteString
    }

    var completionDescription: String {
        if completionKind == .alreadyOnNAS {
            return "复用 NAS 已有副本，未新增文件"
        }
        if state == .completed && verifiedAt == nil {
            return "旧版仅按大小判定，请重新核验实际路径"
        }
        if state == .completed {
            return "目标目录中已确认文件"
        }
        return state.title
    }
    var shouldDeleteSource: Bool?
    var fileSize: Int64
    var sourceModifiedAt: Date?
    var transferredBytes: Int64
    var state: ArchiveTaskState
    var errorMessage: String?
    var sourceDeleted: Bool
    var createdAt: Date

    var progress: Double {
        guard fileSize > 0 else { return state == .completed ? 1 : 0 }
        return min(1, max(0, Double(transferredBytes) / Double(fileSize)))
    }

    init(
        bookmark: Data,
        displayName: String,
        remoteFileName: String,
        remoteRelativePath: String? = nil,
        sourceLocationID: UUID? = nil,
        sourceRelativePath: String? = nil,
        fileSize: Int64,
        sourceModifiedAt: Date?
    ) {
        self.id = UUID()
        self.bookmark = bookmark
        self.displayName = displayName
        self.remoteFileName = remoteFileName
        self.remoteRelativePath = remoteRelativePath
        self.sourceLocationID = sourceLocationID
        self.sourceRelativePath = sourceRelativePath
        self.isShareStaging = nil
        self.remoteVerifiedPath = nil
        self.remoteEndpointURL = nil
        self.attemptedRemotePath = nil
        self.verifiedAt = nil
        self.completionKind = nil
        self.shouldDeleteSource = nil
        self.fileSize = fileSize
        self.sourceModifiedAt = sourceModifiedAt
        self.transferredBytes = 0
        self.state = .queued
        self.errorMessage = nil
        self.sourceDeleted = false
        self.createdAt = Date()
    }
}

struct SourceLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var bookmark: Data
    var displayName: String
    var addedAt: Date
    var lastScannedAt: Date?
    var lastFileCount: Int
    var lastTotalBytes: Int64

    init(bookmark: Data, displayName: String) {
        self.id = UUID()
        self.bookmark = bookmark
        self.displayName = displayName
        self.addedAt = Date()
        self.lastScannedAt = nil
        self.lastFileCount = 0
        self.lastTotalBytes = 0
    }
}

enum DuplicateDecision: String, Codable, CaseIterable {
    case unresolved
    case keepNAS
    case keepPhone
    case keepBoth

    var title: String {
        switch self {
        case .unresolved: return "未处理"
        case .keepNAS: return "只保留 NAS"
        case .keepPhone: return "只保留手机"
        case .keepBoth: return "两边都保留"
        }
    }
}

struct DuplicateCandidate: Identifiable, Codable, Equatable {
    let id: UUID
    let taskID: UUID
    let remotePath: String
    let remoteName: String
    let fileSize: Int64
    var decision: DuplicateDecision

    init(taskID: UUID, remotePath: String, remoteName: String, fileSize: Int64) {
        self.id = UUID()
        self.taskID = taskID
        self.remotePath = remotePath
        self.remoteName = remoteName
        self.fileSize = fileSize
        self.decision = .unresolved
    }
}

struct BatchVerification: Codable, Equatable {
    var expectedCount: Int
    var expectedBytes: Int64
    var verifiedCount: Int
    var verifiedBytes: Int64
    var checkedAt: Date

    var passed: Bool {
        expectedCount == verifiedCount && expectedBytes == verifiedBytes
    }
}
