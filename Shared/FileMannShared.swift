import Foundation
import UniformTypeIdentifiers

enum FileMannShared {
    static let appGroupID = "group.com.masakacj.filemann"
    static let changeGenerationKey = "media.change.generation"

    enum SharedError: LocalizedError {
        case appGroupUnavailable
        case mediaDirectoryUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "FileMann App Group 不可用。自签时需要保留 group.com.masakacj.filemann 权限。"
            case .mediaDirectoryUnavailable:
                return "无法创建 FileMann 媒体目录。"
            }
        }
    }

    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw SharedError.appGroupUnavailable
        }
        return url
    }

    static func mediaDirectory() throws -> URL {
        let root = try containerURL()
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func sidecarDirectory() throws -> URL {
        let root = try containerURL()
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func sidecarURL(for mediaURL: URL) throws -> URL {
        try sidecarDirectory()
            .appendingPathComponent(mediaURL.lastPathComponent + ".json")
    }

    static func uniqueDestination(
        suggestedName: String?,
        sourceURL: URL?,
        typeIdentifier: String?
    ) throws -> URL {
        let directory = try mediaDirectory()
        let inferredExtension: String = {
            if let ext = sourceURL?.pathExtension, !ext.isEmpty {
                return ext
            }
            if let typeIdentifier,
               let type = UTType(typeIdentifier),
               let ext = type.preferredFilenameExtension {
                return ext
            }
            return "bin"
        }()

        var name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            name = "Media-(Self.timestamp()).(inferredExtension)"
        } else if (name as NSString).pathExtension.isEmpty {
            name += ".(inferredExtension)"
        }

        name = sanitizeFileName(name)
        var candidate = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var index = 2

        while true {
            let fileName = ext.isEmpty
                ? "(base) ((index))"
                : "(base) ((index)).(ext)"
            candidate = directory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func noteLibraryChanged() {
        let defaults = UserDefaults(suiteName: appGroupID)
        let next = (defaults?.integer(forKey: changeGenerationKey) ?? 0) + 1
        defaults?.set(next, forKey: changeGenerationKey)
    }

    static func currentGeneration() -> Int {
        UserDefaults(suiteName: appGroupID)?.integer(forKey: changeGenerationKey) ?? 0
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func sanitizeFileName(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return input.components(separatedBy: invalid).joined(separator: "_")
    }
}
