import CryptoKit
import Foundation

/// A local-only, bounded comparison for media with identical byte counts.
/// We never use a checksum to assert that a NAS file was uploaded: remote
/// duplicates still require the existing full byte-for-byte comparison.
enum ArchiveSourceFingerprint {
    static func sha256(of sourceURL: URL, expectedBytes: Int64) throws -> Data {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        guard scoped ||
              FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw WebDAVArchiveError.sourceUnavailable
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        var digest = SHA256()
        var bytesRead: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += Int64(chunk.count)
            guard bytesRead <= expectedBytes else {
                throw WebDAVArchiveError.sourceChanged
            }
            digest.update(data: chunk)
        }
        guard bytesRead == expectedBytes else {
            throw WebDAVArchiveError.sourceChanged
        }
        return Data(digest.finalize())
    }
}
