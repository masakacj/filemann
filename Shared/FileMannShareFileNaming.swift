import Foundation
import UniformTypeIdentifiers

/// Names a file received from Photos / Files without using the temporary
/// NSItemProvider export filename as if it were the original media title.
/// The original filename is available only when the share provider exposes it.
enum FileMannShareFileNaming {
    static func preferredName(
        suggestedName: String?,
        sourceFilename: String?,
        typeIdentifier: String,
        now: Date = Date(),
        token: UUID = UUID()
    ) -> String {
        let preferredExtension =
            UTType(typeIdentifier)?.preferredFilenameExtension ?? "bin"

        let proposed = meaningfulName(suggestedName)
        let source = meaningfulName(sourceFilename)

        if let proposed {
            // If the suggestion is just "IMG_1234" and the file provider
            // supplies "IMG_1234.MOV", preserve the actual extension.
            if let source,
               (proposed as NSString).pathExtension.isEmpty,
               (source as NSString).deletingPathExtension
                    .caseInsensitiveCompare(proposed) == .orderedSame {
                return cleanFilename(source, fileExtension: preferredExtension)
            }
            return cleanFilename(proposed, fileExtension: preferredExtension)
        }
        if let source {
            return cleanFilename(source, fileExtension: preferredExtension)
        }

        // The Photos extension cannot always access PHAssetResource.
        // In that case generate a unique, recognizable name instead of
        // repeatedly uploading "shared-media.mp4".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let prefix = UTType(typeIdentifier)?.conforms(to: .movie) == true
            ? "VID" : "IMG"
        let suffix = String(token.uuidString.prefix(8)).uppercased()
        return "\(prefix)_\(formatter.string(from: now))_\(suffix).\(preferredExtension)"
    }

    private static func meaningfulName(_ value: String?) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let filename = (raw as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let generic: Set<String> = [
            "shared-media", "shared_media", "sharedmedia",
            "image", "video", "movie", "file", "media",
            "fullsizeoutput", "tmp", "temporary"
        ]
        guard !stem.isEmpty, !generic.contains(stem) else {
            return nil
        }
        // A filename consisting solely of a UUID is usually the provider's
        // temporary staging name, not a user-supplied Photos filename.
        if UUID(uuidString: stem) != nil { return nil }
        return filename
    }

    private static func cleanFilename(
        _ value: String,
        fileExtension: String
    ) -> String {
        let candidate = (value as NSString).lastPathComponent
        let currentExtension = (candidate as NSString).pathExtension
        let extensionName = currentExtension.isEmpty
            ? fileExtension : currentExtension
        let stem = currentExtension.isEmpty
            ? candidate
            : (candidate as NSString).deletingPathExtension
        let permitted = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._- ()[]")
        )
        let cleaned = String(stem.unicodeScalars.map {
            permitted.contains($0) ? Character($0) : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let shortStem = String(cleaned.prefix(140))
        let name = shortStem.isEmpty ? "media" : shortStem
        let cleanExtension = String(extensionName.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
        return name + "." + cleanExtension
    }

    /// Called inside an NSItemProvider callback while its temporary source
    /// URL is still valid. Try a hard link before the unavoidable copy.
    static func stage(
        sourceURL: URL,
        suggestedName: String?,
        typeIdentifier: String,
        in inbox: URL
    ) throws -> URL {
        let filename = preferredName(
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
