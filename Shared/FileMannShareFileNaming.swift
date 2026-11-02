import Foundation
import UniformTypeIdentifiers

/// The App Group staging name is private. The NAS name must be the exact
/// filename provided by Photos / Files, except a collision suffix.
/// Never synthesize a name, transliterate Unicode, replace punctuation,
/// truncate the stem, or change an extension's spelling/case.
enum FileMannShareFileNaming {
    enum NameError: LocalizedError {
        case originalFilenameUnavailable
        case invalidOriginalFilename

        var errorDescription: String? {
            switch self {
            case .originalFilenameUnavailable:
                return "分享来源未提供可靠的原文件名，已停止导入。不会改成 shared-media、VID 或随机名称；请从“文件”App 选择保留原名的文件，或换一种提供原名的分享方式。"
            case .invalidOriginalFilename:
                return "分享来源文件名无法原样用于存储（包含路径分隔符或无效字符），已停止导入，不会擅自改名。"
            }
        }
    }

    /// typeIdentifier is intentionally not used to append a guessed
    /// extension. If only an extensionless name is available, the original
    /// full filename is unknown.
    static func preferredName(
        suggestedName: String?,
        sourceFilename: String?,
        typeIdentifier: String
    ) throws -> String {
        let suggested = try validatedOriginal(suggestedName)
        let source = try validatedOriginal(sourceFilename)

        if let suggested {
            if (suggested as NSString).pathExtension.isEmpty {
                if let source,
                   (source as NSString).deletingPathExtension == suggested,
                   !(source as NSString).pathExtension.isEmpty {
                    return source
                }
                throw NameError.originalFilenameUnavailable
            }
            return suggested
        }
        if let source, !(source as NSString).pathExtension.isEmpty {
            return source
        }
        throw NameError.originalFilenameUnavailable
    }

    /// Disallow synthetic fallback names produced by older releases.
    /// Existing completed uploads remain untouched; pending shares without
    /// a known original must be renamed by the user or reimported.
    static func isReliableOriginalFilename(_ value: String) -> Bool {
        (try? validatedOriginal(value)) != nil &&
            !(value as NSString).pathExtension.isEmpty
    }

    private static func validatedOriginal(_ value: String?) throws -> String? {
        guard let value else { return nil }
        if value.isEmpty ||
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            value == "." || value == ".." {
            return nil
        }
        guard !value.contains("/"), !value.contains("\\"),
              !value.contains("\0") else {
            throw NameError.invalidOriginalFilename
        }

        let stem = (value as NSString).deletingPathExtension.lowercased()
        let generic: Set<String> = [
            "shared-media", "shared_media", "sharedmedia",
            "image", "video", "movie", "file", "media",
            "fullsizeoutput", "tmp", "temporary",
            "temporary-file", "temp", "untitled"
        ]
        if generic.contains(stem) || UUID(uuidString: stem) != nil {
            return nil
        }
        // Earlier FileMann versions generated names without having obtained
        // an original filename. Do not regard these as original names.
        if stem.range(
            of: #"^(vid|img)_[0-9]{8}_[0-9]{6}_[0-9a-f]{8}$"#,
            options: .regularExpression
        ) != nil {
            return nil
        }
        return value
    }

    /// Preserve the source filename byte-for-byte except an explicit numeric
    /// suffix before the original extension. Used only when names collide,
    /// and never for otherwise unique media files.
    static func addingDuplicateSuffix(
        to original: String,
        number: Int
    ) -> String {
        precondition(number >= 2)
        let extensionName = (original as NSString).pathExtension
        guard !extensionName.isEmpty else {
            return original + " (\(number))"
        }
        let stem = (original as NSString).deletingPathExtension
        return stem + " (\(number))." + extensionName
    }

    /// The UUID prefix is used only inside the staging inbox to allow two
    /// photos with the same filename to coexist. It is removed at import.
    static func stage(
        sourceURL: URL,
        suggestedName: String?,
        typeIdentifier: String,
        in inbox: URL
    ) throws -> URL {
        let filename = try preferredName(
            suggestedName: suggestedName,
            sourceFilename: sourceURL.lastPathComponent,
            typeIdentifier: typeIdentifier
        )
        let destination = inbox.appendingPathComponent(
            UUID().uuidString.lowercased() + "__" + filename
        )

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        var coordinationError: NSError?
        var transferError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinationError
        ) { coordinated in
            do {
                do {
                    try FileManager.default.linkItem(
                        at: coordinated, to: destination
                    )
                } catch {
                    try FileManager.default.copyItem(
                        at: coordinated, to: destination
                    )
                }
            } catch {
                transferError = error
            }
        }
        if let issue = transferError ?? coordinationError {
            try? FileManager.default.removeItem(at: destination)
            throw issue
        }
        return destination
    }
}
