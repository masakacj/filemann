import Foundation
import UniformTypeIdentifiers

enum MediaImportSource: String, Codable, Hashable, Sendable {
    case share
    case photoPicker
}

struct MediaImportMetadata: Codable, Hashable, Sendable {
    var source: MediaImportSource
    var sourceAssetIdentifier: String?
    var importedAt: Date
    var photoDeletedAt: Date?

    init(
        source: MediaImportSource,
        sourceAssetIdentifier: String? = nil,
        importedAt: Date = Date(),
        photoDeletedAt: Date? = nil
    ) {
        self.source = source
        self.sourceAssetIdentifier = sourceAssetIdentifier
        self.importedAt = importedAt
        self.photoDeletedAt = photoDeletedAt
    }
}

enum FileMannShared {
    static let changeGenerationKey = "media.change.generation"

    static func mediaRootDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root = appSupport
            .appendingPathComponent("FileMann", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func mediaDirectory() throws -> URL {
        let root = try mediaRootDirectory()
            .appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func sidecarDirectory() throws -> URL {
        let root = try mediaRootDirectory()
            .appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func importMetadataDirectory() throws -> URL {
        let root = try mediaRootDirectory()
            .appendingPathComponent("Imports", isDirectory: true)
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

    static func importMetadataURL(for mediaURL: URL) throws -> URL {
        try importMetadataDirectory()
            .appendingPathComponent(mediaURL.lastPathComponent + ".json")
    }

    static func loadImportMetadata(for mediaURL: URL) -> MediaImportMetadata? {
        guard let url = try? importMetadataURL(for: mediaURL),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(MediaImportMetadata.self, from: data)
    }

    static func saveImportMetadata(
        _ metadata: MediaImportMetadata,
        for mediaURL: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        let url = try importMetadataURL(for: mediaURL)
        try data.write(to: url, options: [.atomic])
    }

    static func markPhotoDeleted(for mediaURL: URL) {
        guard var metadata = loadImportMetadata(for: mediaURL) else { return }
        metadata.photoDeletedAt = Date()
        try? saveImportMetadata(metadata, for: mediaURL)
    }

    static func removeCompanionFiles(for mediaURL: URL) {
        if let sidecar = try? sidecarURL(for: mediaURL) {
            try? FileManager.default.removeItem(at: sidecar)
        }
        if let importMetadata = try? importMetadataURL(for: mediaURL) {
            try? FileManager.default.removeItem(at: importMetadata)
        }
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
            name = "Media-\(Self.timestamp()).\(inferredExtension)"
        } else if (name as NSString).pathExtension.isEmpty {
            name += ".\(inferredExtension)"
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
                ? "\(base) (\(index))"
                : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    static func noteLibraryChanged() {
        let defaults = UserDefaults.standard
        let next = defaults.integer(forKey: changeGenerationKey) + 1
        defaults.set(next, forKey: changeGenerationKey)
    }

    static func currentGeneration() -> Int {
        UserDefaults.standard.integer(forKey: changeGenerationKey)
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
