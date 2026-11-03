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

    /// Local-only metadata for Photos shares, never sent to the NAS.
    /// Position refers to the original selection order, so an unresolved
    /// item can be identified even when iOS supplies "shared-media.mp4".
    struct StagedMetadata: Codable, Equatable {
        let selectionIndex: Int
        let needsFilenameDecision: Bool
    }

    static func metadataURL(for stagedFile: URL) -> URL {
        stagedFile.appendingPathExtension("filemann-share.json")
    }

    static func readMetadata(for stagedFile: URL) -> StagedMetadata? {
        guard let data = try? Data(
            contentsOf: metadataURL(for: stagedFile)
        ) else { return nil }
        return try? JSONDecoder().decode(StagedMetadata.self, from: data)
    }

    static func isGeneratedPlaceholderName(_ name: String) -> Bool {
        name.range(
            of: #"^FileMann-待命名-[0-9a-f]{12}\.[a-z0-9]+$"#,
            options: [.caseInsensitive, .regularExpression]
        ) != nil
    }

    /// Stage every readable image/video, including ones with no trustworthy
    /// original filename. Its unique name is a *temporary local label*;
    /// the main app requires an explicit rename or placeholder approval
    /// before scheduling a NAS upload.
    static func stageForQueue(
        sourceURL: URL,
        suggestedName: String?,
        typeIdentifier: String,
        selectionIndex: Int,
        in inbox: URL
    ) throws -> URL {
        // The provider's source may be a security-scoped URL. The signature
        // probe and the copy must happen while this scope is open.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        // Never label transcoded JPEG bytes as a HEIC original. The share
        // host controls which representations it vends; the extension
        // cannot reverse a JPEG conversion by renaming the file.
        let signature = try FileMannMediaRepresentation
            .verifyOriginalRepresentation(
                at: sourceURL,
                typeIdentifier: typeIdentifier,
                suggestedName: suggestedName
            )
        let filename: String
        let unresolved: Bool

        do {
            let suggestedCandidate = try preferredName(
                suggestedName: suggestedName,
                sourceFilename: sourceURL.lastPathComponent,
                typeIdentifier: typeIdentifier
            )
            if signature == .heic {
                // Photos can claim JPG as its preferred display name even
                // while the requested provider supplies actual HEIC bytes.
                // A credible file URL with a HEIC original filename wins.
                let sourceCandidate = try? preferredName(
                    suggestedName: nil,
                    sourceFilename: sourceURL.lastPathComponent,
                    typeIdentifier: typeIdentifier
                )
                let sourceExt = ((sourceCandidate ?? "") as NSString)
                    .pathExtension.lowercased()
                let useSource = sourceExt == "heic" ||
                    sourceExt == "heif"
                let candidate = useSource
                    ? sourceCandidate! : suggestedCandidate
                let ext = (candidate as NSString).pathExtension.lowercased()
                guard ext == "heic" || ext == "heif" else {
                    throw NameError.originalFilenameUnavailable
                }
                filename = candidate
            } else {
                filename = suggestedCandidate
            }
            unresolved = false
        } catch NameError.originalFilenameUnavailable {
            filename = temporaryPlaceholder(
                for: typeIdentifier,
                actualFormat: signature
            )
            unresolved = true
        } catch NameError.invalidOriginalFilename {
            filename = temporaryPlaceholder(
                for: typeIdentifier,
                actualFormat: signature
            )
            unresolved = true
        }

        let staged = try stage(
            sourceURL: sourceURL,
            suggestedName: filename,
            typeIdentifier: typeIdentifier,
            in: inbox
        )
        do {
            let metadata = StagedMetadata(
                selectionIndex: selectionIndex,
                needsFilenameDecision: unresolved
            )
            try JSONEncoder().encode(metadata).write(
                to: metadataURL(for: staged),
                options: .atomic
            )
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: metadataURL(for: staged))
            throw error
        }
    }

    /// Generated only for local staging. Never silently accepted as the
    /// original filename; collision handling for the approved final name
    /// remains in ArchiveViewModel.
    private static func temporaryPlaceholder(
        for typeIdentifier: String,
        actualFormat: FileMannMediaRepresentation.FileSignature = .other
    ) -> String {
        let type = UTType(typeIdentifier)
        let fileExtension: String
        switch actualFormat {
        case .heic: fileExtension = "heic"
        case .jpeg: fileExtension = "jpg"
        case .png: fileExtension = "png"
        case .other:
            fileExtension = type?.preferredFilenameExtension ??
                (type?.conforms(to: .movie) == true ? "mov" : "jpg")
        }
        let marker = String(
            UUID().uuidString.replacingOccurrences(
                of: "-", with: ""
            ).prefix(12)
        )
        return "FileMann-待命名-\(marker).\(fileExtension)"
    }

    static func discardStagedFile(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        let metadata = metadataURL(for: url)
        if manager.fileExists(atPath: metadata.path) {
            try manager.removeItem(at: metadata)
        }
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
