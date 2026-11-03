import Foundation

/// Independent recovery journal for URLSession callbacks. A suspended app
/// may be relaunched only long enough for URLSession's delegate callbacks:
/// a WebDAV MOVE/PROPFIND confirmation can finish before SwiftUI creates its
/// observer. Write the verified receipt first, then notify the UI.
struct WebDAVBackgroundReceipt: Codable, Equatable {
    enum Outcome: String, Codable {
        case verified
        case failed
    }

    let taskID: UUID
    let outcome: Outcome
    let endpoint: String?
    let remotePath: String?
    let remoteSize: Int64?
    let message: String?
    let recordedAt: Date

    /// Only a receipt for the same task, exact upload endpoint, target
    /// path and expected byte count can restore a verified archive.
    func matchesVerifiedUpload(_ task: ArchiveTask) -> Bool {
        outcome == .verified &&
        taskID == task.id &&
        endpoint == task.remoteEndpointURL &&
        remotePath == task.attemptedRemotePath &&
        remoteSize == task.fileSize &&
        remoteSize != nil
    }

    static func verified(
        taskID: UUID, endpoint: String, path: String,
        size: Int64
    ) -> WebDAVBackgroundReceipt {
        WebDAVBackgroundReceipt(
            taskID: taskID, outcome: .verified,
            endpoint: endpoint, remotePath: path,
            remoteSize: size, message: nil,
            recordedAt: Date()
        )
    }

    static func failed(
        taskID: UUID, message: String
    ) -> WebDAVBackgroundReceipt {
        WebDAVBackgroundReceipt(
            taskID: taskID, outcome: .failed,
            endpoint: nil, remotePath: nil,
            remoteSize: nil, message: message,
            recordedAt: Date()
        )
    }
}

enum WebDAVBackgroundReceiptStore {
    private static func directory(
        under root: URL?
    ) throws -> URL {
        let base: URL
        if let root {
            base = root
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = base.appendingPathComponent(
            "FileMann/BackgroundReceipts", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    private static func path(
        for id: UUID, under root: URL?
    ) throws -> URL {
        try directory(under: root).appendingPathComponent(
            id.uuidString.lowercased() + ".json"
        )
    }

    static func save(
        _ receipt: WebDAVBackgroundReceipt,
        under root: URL? = nil
    ) throws {
        let data = try JSONEncoder().encode(receipt)
        try data.write(
            to: path(for: receipt.taskID, under: root),
            options: [.atomic]
        )
    }

    static func load(
        under root: URL? = nil
    ) -> [WebDAVBackgroundReceipt] {
        guard let folder = try? directory(under: root),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file) else {
                return nil
            }
            return try? JSONDecoder().decode(
                WebDAVBackgroundReceipt.self,
                from: data
            )
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    static func remove(
        taskID: UUID,
        under root: URL? = nil
    ) {
        guard let file = try? path(for: taskID, under: root) else {
            return
        }
        try? FileManager.default.removeItem(at: file)
    }
}
