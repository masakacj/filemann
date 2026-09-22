import Foundation

enum ArchiveTaskState: String, Codable {
    case queued
    case uploading
    case paused
    case completed
    case failed
    case missingSource

    var title: String {
        switch self {
        case .queued: return "等待"
        case .uploading: return "上传中"
        case .paused: return "已暂停"
        case .completed: return "已归档"
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
        fileSize: Int64,
        sourceModifiedAt: Date?
    ) {
        self.id = UUID()
        self.bookmark = bookmark
        self.displayName = displayName
        self.remoteFileName = remoteFileName
        self.fileSize = fileSize
        self.sourceModifiedAt = sourceModifiedAt
        self.transferredBytes = 0
        self.state = .queued
        self.errorMessage = nil
        self.sourceDeleted = false
        self.createdAt = Date()
    }
}
