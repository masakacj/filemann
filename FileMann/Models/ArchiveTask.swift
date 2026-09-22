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

struct ArchiveTask: Identifiable, Codable, Equatable {
    let id: UUID
    var bookmark: Data
    var displayName: String
    var remoteFileName: String
    var remoteRelativePath: String?
    var sourceLocationID: UUID?
    var sourceRelativePath: String?
    var remoteVerifiedPath: String?
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
        self.remoteVerifiedPath = nil
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
