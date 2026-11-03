import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

/// Exporting "unmodified originals" can leave hundreds of files with the
/// exact same filesystem mtime. Preserve the original EXIF shooting date
/// when available and always provide a deterministic filename tie-breaker.
struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: MediaKind
    let fileSize: Int64
    let modifiedAt: Date
    let capturedAt: Date?
    let importMetadata: MediaImportMetadata?

    /// Capture date for HEIC/JPEG originals; filesystem date otherwise.
    var preferredDate: Date {
        capturedAt ?? modifiedAt
    }

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return nil
        }

        let kind: MediaKind
        if type.conforms(to: .image) {
            kind = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            kind = .video
        } else {
            return nil
        }

        let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey
            ]
        )
        if values?.isRegularFile == false {
            return nil
        }

        self.id = url.standardizedFileURL.path
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.modifiedAt = values?.contentModificationDate ??
            values?.creationDate ?? .distantPast
        self.capturedAt = kind == .image
            ? Self.imageCaptureDate(at: url)
            : nil
        self.importMetadata = FileMannShared.loadImportMetadata(for: url)
    }

    private static func imageCaptureDate(at url: URL) -> Date? {
        // Read metadata without decoding the full HEIC/RAW/JPEG pixel data.
        // A large batch of iCloud exports must not inflate app memory.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            options as CFDictionary
        ), let metadata = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil
        ) as? [String: Any] else {
            return nil
        }

        let exif = metadata[
            kCGImagePropertyExifDictionary as String
        ] as? [String: Any]
        let tiff = metadata[
            kCGImagePropertyTIFFDictionary as String
        ] as? [String: Any]

        let dateString =
            (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String) ??
            (exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String) ??
            (tiff?[kCGImagePropertyTIFFDateTime as String] as? String)

        guard let dateString else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // EXIF often lacks timezone data. Use device local timezone.
        formatter.timeZone = .current
        return formatter.date(from: dateString)
    }
}

enum MediaLibrarySortOrder: String, CaseIterable, Identifiable {
    case shootingNewest
    case shootingOldest
    case filenameAscending
    case filenameDescending
    case modifiedNewest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shootingNewest: return "拍摄时间 · 从新到旧"
        case .shootingOldest: return "拍摄时间 · 从旧到新"
        case .filenameAscending: return "原文件名 · A–Z"
        case .filenameDescending: return "原文件名 · Z–A"
        case .modifiedNewest: return "文件修改时间 · 从新到旧"
        }
    }

    var groupsByDay: Bool {
        switch self {
        case .shootingNewest, .shootingOldest, .modifiedNewest:
            return true
        case .filenameAscending, .filenameDescending:
            return false
        }
    }
}

enum MediaLibraryOrdering {
    static func sorted(
        _ items: [MediaItem],
        by order: MediaLibrarySortOrder
    ) -> [MediaItem] {
        items.sorted { a, b in
            switch order {
            case .shootingNewest, .shootingOldest:
                if a.preferredDate != b.preferredDate {
                    return order == .shootingNewest
                        ? a.preferredDate > b.preferredDate
                        : a.preferredDate < b.preferredDate
                }
            case .modifiedNewest:
                if a.modifiedAt != b.modifiedAt {
                    return a.modifiedAt > b.modifiedAt
                }
            case .filenameAscending:
                return filenameLess(a, b)
            case .filenameDescending:
                return filenameLess(b, a)
            }
            // Stable when hundreds of exported files share the same mtime.
            return filenameLess(a, b)
        }
    }

    private static func filenameLess(
        _ lhs: MediaItem,
        _ rhs: MediaItem
    ) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
