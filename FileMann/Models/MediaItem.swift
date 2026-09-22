import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: MediaKind
    let fileSize: Int64
    let modifiedAt: Date
    let importMetadata: MediaImportMetadata?

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
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )

        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.kind = kind
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.modifiedAt = values?.contentModificationDate ?? .distantPast
        self.importMetadata = FileMannShared.loadImportMetadata(for: url)
    }
}
