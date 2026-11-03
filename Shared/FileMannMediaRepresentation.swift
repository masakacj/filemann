import Foundation
import UniformTypeIdentifiers

/// Selects the highest-fidelity representation actually advertised by an
/// NSItemProvider. The Photos share sheet can advertise both HEIC and JPEG;
/// requesting a generic image or the JPEG representation silently transcodes.
/// A provider advertising only JPEG cannot be forced to yield HEIC.
enum FileMannMediaRepresentation {
    enum RepresentationError: LocalizedError {
        case missingMedia
        case convertedHEICToJPEG
        case mismatchedHEICData

        var errorDescription: String? {
            switch self {
            case .missingMedia:
                return "分享来源没有提供可读取的照片或视频文件"
            case .convertedHEICToJPEG:
                return "iOS 提供的是 JPEG 而不是原 HEIC。请在“照片 → 分享 → 选项 → 格式”选择“当前”，或使用 FileMann 内“选择相册原件”。不会将 JPEG 假装成 HEIC 上传。"
            case .mismatchedHEICData:
                return "收到的文件类型与 HEIC 声明不一致，已阻止错误格式的归档"
            }
        }
    }

    enum FileSignature: Equatable {
        case heic
        case jpeg
        case png
        case other
    }

    static func preferredTypeIdentifier(
        from registered: [String]
    ) -> String? {
        let supported = registered.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) ||
                type.conforms(to: .movie) ||
                type.conforms(to: .video)
        }
        // Explicitly prefer high-efficiency originals over compatibility
        // JPEG, irrespective of the provider's ordering.
        if let heic = supported.first(where: {
            $0 == UTType.heic.identifier ||
                $0 == UTType.heif.identifier
        }) {
            return heic
        }
        return supported.first(where: { identifier in
            guard let t = UTType(identifier) else { return false }
            return t != .image && t != .movie && t != .video
        }) ?? supported.first
    }

    static func fileSignature(at url: URL) throws -> FileSignature {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = file.readData(ofLength: 32)
        return signature(of: header)
    }

    static func signature(of header: Data) -> FileSignature {
        let bytes = Array(header.prefix(32))
        if bytes.count >= 3, Array(bytes.prefix(3)) == [0xFF, 0xD8, 0xFF] {
            return .jpeg
        }
        if bytes.count >= 8,
           Array(bytes.prefix(8)) ==
                [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .png
        }
        if bytes.count >= 12,
           Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(
                decoding: bytes[8..<12], as: UTF8.self
            ).lowercased()
            if ["heic", "heix", "hevc", "hevx", "heim",
                "heis", "mif1", "msf1"].contains(brand) {
                return .heic
            }
        }
        return .other
    }

    static func verifyOriginalRepresentation(
        at url: URL,
        typeIdentifier: String,
        suggestedName: String?
    ) throws -> FileSignature {
        let signature = try fileSignature(at: url)
        let type = UTType(typeIdentifier)
        let heicRequested = type == .heic || type == .heif
        let claimedHEIC = [url.lastPathComponent, suggestedName ?? ""]
            .contains { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return ext == "heic" || ext == "heif"
            }

        if signature == .jpeg && (heicRequested || claimedHEIC) {
            throw RepresentationError.convertedHEICToJPEG
        }
        if heicRequested && signature != .heic {
            throw RepresentationError.mismatchedHEICData
        }
        return signature
    }

    /// NSItemProvider's temporary URL is only valid inside its callback.
    /// Complete staging before resuming the continuation.
    static func stageProvider(
        _ provider: NSItemProvider,
        selectionIndex: Int,
        inbox: URL,
        originalFilenameHint: String? = nil
    ) async throws -> URL {
        guard let identifier = preferredTypeIdentifier(
            from: provider.registeredTypeIdentifiers
        ) else {
            throw RepresentationError.missingMedia
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: identifier
            ) { url, _, _ in
                if let url {
                    do {
                        let staged = try FileMannShareFileNaming.stageForQueue(
                            sourceURL: url,
                            suggestedName: originalFilenameHint ??
                                provider.suggestedName,
                            typeIdentifier: identifier,
                            selectionIndex: selectionIndex,
                            in: inbox
                        )
                        continuation.resume(returning: staged)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                provider.loadFileRepresentation(
                    forTypeIdentifier: identifier
                ) { temporaryURL, error in
                    guard let temporaryURL else {
                        continuation.resume(
                            throwing: error ?? RepresentationError.missingMedia
                        )
                        return
                    }
                    do {
                        let staged = try FileMannShareFileNaming.stageForQueue(
                            sourceURL: temporaryURL,
                            suggestedName: originalFilenameHint ??
                                provider.suggestedName,
                            typeIdentifier: identifier,
                            selectionIndex: selectionIndex,
                            in: inbox
                        )
                        continuation.resume(returning: staged)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
