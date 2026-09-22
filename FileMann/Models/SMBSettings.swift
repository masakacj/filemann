import Foundation

struct SMBSettings: Codable, Equatable {
    var host: String = ""
    var share: String = ""
    var remoteDirectory: String = ""
    var username: String = ""
    var deleteAfterArchive: Bool = true
    var chunkSizeMB: Int = 16

    var normalizedHost: String {
        host
            .replacingOccurrences(of: "smb://", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedShare: String {
        share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedDirectory: String {
        remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var isValid: Bool {
        !normalizedHost.isEmpty && !normalizedShare.isEmpty
    }
}
