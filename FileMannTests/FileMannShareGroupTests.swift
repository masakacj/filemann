import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import FileMann

final class FileMannShareGroupTests: XCTestCase {
    func testFindsAllowedGroupsInSelfSignedProvisioningProfile() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Entitlements</key><dict>
            <key>com.apple.security.application-groups</key>
            <array>
              <string>group.example.owner.1</string>
              <string>group.example.owner.5</string>
            </array>
          </dict>
        </dict></plist>
        """
        // The XML is CMS-wrapped in real embedded.mobileprovision files.
        var profile = Data([0x30, 0x82, 0xff, 0x00])
        profile.append(Data(xml.utf8))
        profile.append(contentsOf: [0xff, 0xff, 0x00])

        XCTAssertEqual(
            FileMannShareGroup.provisionedGroups(in: profile),
            ["group.example.owner.1", "group.example.owner.5"]
        )
    }

    func testMissingGroupNeverCreatesArbitrarySharedStorage() {
        let xml = """
        <?xml version="1.0"?>
        <plist version="1.0"><dict>
          <key>Entitlements</key><dict/>
        </dict></plist>
        """
        XCTAssertTrue(
            FileMannShareGroup.provisionedGroups(
                in: Data(xml.utf8)
            ).isEmpty
        )
    }
    func testPhotosSourceFilenameOverridesGenericSuggestedName() throws {
        XCTAssertEqual(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "shared-media.mp4",
                sourceFilename: "IMG_3847.MOV",
                typeIdentifier: "com.apple.quicktime-movie"
            ),
            "IMG_3847.MOV"
        )
        XCTAssertEqual(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "IMG_1024",
                sourceFilename: "IMG_1024.HEIC",
                typeIdentifier: "public.heic"
            ),
            "IMG_1024.HEIC"
        )
    }

    func testPhotosOriginalUnicodePunctuationSpacesAndCasePreserved() throws {
        let original = "夜🌸 热门 %20 [甲] #!+ (1) .MP4"
        XCTAssertEqual(
            try FileMannShareFileNaming.preferredName(
                suggestedName: original,
                sourceFilename: "temporary-file.mp4",
                typeIdentifier: "public.mpeg-4"
            ),
            original
        )
        let chinese = "原始 视频🥰（高清）.MOV"
        XCTAssertEqual(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "shared-media.mp4",
                sourceFilename: chinese,
                typeIdentifier: "public.mpeg-4"
            ),
            chinese
        )
    }

    func testGenericProviderNameNeverCreatesFakeOriginal() {
        XCTAssertThrowsError(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "shared-media.mp4",
                sourceFilename: "shared-media.mp4",
                typeIdentifier: "public.mpeg-4"
            )
        )
        XCTAssertThrowsError(
            try FileMannShareFileNaming.preferredName(
                suggestedName: nil,
                sourceFilename: "CEDCA419-DA02-4AF2-BC00-DEFCA8E283C1.mp4",
                typeIdentifier: "public.mpeg-4"
            )
        )
        XCTAssertThrowsError(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "IMG_1000",
                sourceFilename: "temporary-file.mp4",
                typeIdentifier: "public.mpeg-4"
            )
        )
        XCTAssertFalse(FileMannShareFileNaming.isReliableOriginalFilename(
            "VID_20261102_120000_1234ABCD.mp4"
        ))
    }

    func testDuplicateSuffixOnlyAndBeforeOriginalExtension() {
        XCTAssertEqual(
            FileMannShareFileNaming.addingDuplicateSuffix(
                to: "原始 视频🥰（高清）.MOV", number: 2
            ),
            "原始 视频🥰（高清） (2).MOV"
        )
        XCTAssertEqual(
            FileMannShareFileNaming.addingDuplicateSuffix(
                to: "夜🌸 热门 %20 [甲] #!+.MP4", number: 3
            ),
            "夜🌸 热门 %20 [甲] #!+ (3).MP4"
        )
        XCTAssertEqual(
            FileMannShareFileNaming.addingDuplicateSuffix(
                to: "无扩展名", number: 2
            ),
            "无扩展名 (2)"
        )
    }

    func testFilenameWithPathSeparatorsRejectedRatherThanSanitized() {
        XCTAssertThrowsError(
            try FileMannShareFileNaming.preferredName(
                suggestedName: "original/name.mp4",
                sourceFilename: nil,
                typeIdentifier: "public.mpeg-4"
            )
        )
    }

    func testShareStagingPreservesResolvedOriginalName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("IMG_1234.MOV")
        try Data("share extension media test".utf8).write(to: original)
        let received = try FileMannShareFileNaming.stage(
            sourceURL: original,
            suggestedName: "shared-media.mp4",
            typeIdentifier: "com.apple.quicktime-movie",
            in: root
        )
        XCTAssertTrue(received.lastPathComponent.hasSuffix("__IMG_1234.MOV"))
        XCTAssertEqual(
            try Data(contentsOf: received),
            try Data(contentsOf: original)
        )
    }

    func testShareStagingKeepsExactUnicodeOriginalBytes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let originalName = "🎞️ 原始影片 #1 %20.MP4"
        let original = folder.appendingPathComponent(originalName)
        let payload = Data("media contents".utf8)
        try payload.write(to: original)
        let staged = try FileMannShareFileNaming.stage(
            sourceURL: original,
            suggestedName: originalName,
            typeIdentifier: "public.mpeg-4",
            in: folder
        )
        XCTAssertTrue(staged.lastPathComponent.hasSuffix("__" + originalName))
        XCTAssertEqual(try Data(contentsOf: staged), payload)
    }

    func testUnnamedItem29StagesAndAppearsInQueueMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("FileMann-Share-Inbox")
        try FileManager.default.createDirectory(
            at: inbox, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("shared-media.mp4")
        let bytes = Data(repeating: 0x66, count: 2048)
        try bytes.write(to: source)

        // Before this fix, this exact input throws and the 29th selected
        // photo/video disappears from an otherwise successful large share.
        let staged = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: "shared-media.mp4",
            typeIdentifier: "public.mpeg-4",
            selectionIndex: 29,
            in: inbox
        )
        let originalName = staged.lastPathComponent
            .components(separatedBy: "__").dropFirst()
            .joined(separator: "__")
        XCTAssertTrue(
            FileMannShareFileNaming.isGeneratedPlaceholderName(originalName)
        )
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        XCTAssertTrue(FileMannShared.isSupportedMediaFile(staged))

        let metadata = FileMannShareFileNaming.readMetadata(for: staged)
        XCTAssertEqual(metadata?.selectionIndex, 29)
        XCTAssertEqual(metadata?.needsFilenameDecision, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: FileMannShareFileNaming.metadataURL(
                for: staged
            ).path
        ))

        var task = ArchiveTask(
            bookmark: Data(),
            displayName: originalName,
            remoteFileName: originalName,
            fileSize: Int64(bytes.count),
            sourceModifiedAt: nil
        )
        task.isShareStaging = true
        task.shareFilenameDecision = .pending
        task.shareSelectionIndex = metadata?.selectionIndex

        let restored = try JSONDecoder().decode(
            ArchiveTask.self,
            from: JSONEncoder().encode(task)
        )
        XCTAssertTrue(restored.needsShareFilenameDecision)
        XCTAssertEqual(restored.shareSelectionIndex, 29)
        XCTAssertEqual(restored.completionDescription, "待确认文件名")

        // Clearing a Share staging copy must not touch its source in Photos
        // or Files, and must remove the associated metadata sidecar.
        try FileMannShareFileNaming.discardStagedFile(staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: FileMannShareFileNaming.metadataURL(
                for: staged
            ).path
        ))
    }

    func testKnownFilenameStagesWithOriginalAndNoDecision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "猫猫🎞️ %20 原片.MOV"
        let source = root.appendingPathComponent(original)
        try Data("original".utf8).write(to: source)

        let staged = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: original,
            typeIdentifier: "com.apple.quicktime-movie",
            selectionIndex: 212,
            in: root
        )
        XCTAssertTrue(staged.lastPathComponent.hasSuffix("__" + original))
        let metadata = FileMannShareFileNaming.readMetadata(for: staged)
        XCTAssertEqual(metadata?.selectionIndex, 212)
        XCTAssertEqual(metadata?.needsFilenameDecision, false)
    }

    func testUnnamedSharesGetDistinctLocalPlaceholders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("shared-media.mp4")
        try Data("A".utf8).write(to: source)
        let first = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: "shared-media.mp4",
            typeIdentifier: "public.mpeg-4",
            selectionIndex: 29,
            in: root
        )
        let second = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: "shared-media.mp4",
            typeIdentifier: "public.mpeg-4",
            selectionIndex: 30,
            in: root
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            FileMannShareFileNaming.readMetadata(
                for: first
            )?.needsFilenameDecision,
            true
        )
        XCTAssertEqual(
            FileMannShareFileNaming.readMetadata(
                for: second
            )?.selectionIndex,
            30
        )
    }

    func testPhotosProviderPrefersHEICEvenWhenJPEGIsRegisteredFirst() {
        XCTAssertEqual(
            FileMannMediaRepresentation.preferredTypeIdentifier(
                from: [
                    UTType.jpeg.identifier,
                    UTType.image.identifier,
                    UTType.heic.identifier,
                    UTType.png.identifier
                ]
            ),
            UTType.heic.identifier
        )
        XCTAssertEqual(
            FileMannMediaRepresentation.preferredTypeIdentifier(
                from: [
                    UTType.jpeg.identifier,
                    UTType.heif.identifier
                ]
            ),
            UTType.heif.identifier
        )
        XCTAssertEqual(
            FileMannMediaRepresentation.preferredTypeIdentifier(
                from: [UTType.jpeg.identifier, UTType.image.identifier]
            ),
            UTType.jpeg.identifier
        )
        XCTAssertNil(FileMannMediaRepresentation.preferredTypeIdentifier(
            from: ["public.plain-text"]
        ))
    }

    func testActualHEICBytesAreNotJPEG() throws {
        let heicHeader = Data(
            [0, 0, 0, 24] + Array("ftypheic".utf8) +
            Array(repeating: UInt8(0), count: 16)
        )
        XCTAssertEqual(
            FileMannMediaRepresentation.signature(of: heicHeader),
            .heic
        )
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])
        XCTAssertEqual(
            FileMannMediaRepresentation.signature(of: jpeg),
            .jpeg
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("IMG_4921.HEIC")
        try heicHeader.write(to: source)
        let staged = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: "shared-media.jpeg",
            typeIdentifier: UTType.heic.identifier,
            selectionIndex: 29,
            in: root
        )
        XCTAssertTrue(staged.lastPathComponent.hasSuffix("__IMG_4921.HEIC"))
        XCTAssertEqual(try Data(contentsOf: staged), heicHeader)
        XCTAssertEqual(
            FileMannShareFileNaming.readMetadata(
                for: staged
            )?.needsFilenameDecision,
            false
        )
    }

    func testHEICBytesKeepRealHEICFilenameDespitePhotosJPGSuggestion() throws {
        let header = Data(
            [0, 0, 0, 24] + Array("ftypheic".utf8) +
            Array(repeating: UInt8(0), count: 8)
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = folder.appendingPathComponent("IMG_0036.HEIC")
        try header.write(to: source)
        let stored = try FileMannShareFileNaming.stageForQueue(
            sourceURL: source,
            suggestedName: "IMG_0036.JPG",
            typeIdentifier: UTType.heic.identifier,
            selectionIndex: 1,
            in: folder
        )
        XCTAssertTrue(stored.lastPathComponent.hasSuffix("__IMG_0036.HEIC"))
        XCTAssertFalse(
            FileMannShareFileNaming.readMetadata(
                for: stored
            )?.needsFilenameDecision ?? true
        )
    }

    func testConvertedJPEGCannotMasqueradeAsHEIC() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let jpeg = folder.appendingPathComponent("IMG_4921.JPG")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11]).write(to: jpeg)
        XCTAssertThrowsError(try FileMannShareFileNaming.stageForQueue(
            sourceURL: jpeg,
            suggestedName: "IMG_4921.HEIC",
            typeIdentifier: UTType.jpeg.identifier,
            selectionIndex: 2,
            in: folder
        ))
        XCTAssertThrowsError(try FileMannShareFileNaming.stageForQueue(
            sourceURL: jpeg,
            suggestedName: "IMG_4921.HEIC",
            typeIdentifier: UTType.heic.identifier,
            selectionIndex: 3,
            in: folder
        ))
    }

    func testHEICWithoutExposedOriginalNameStagesAsHEICPendingDecision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let unnamed = root.appendingPathComponent("shared-media.heic")
        let body = Data(
            [0, 0, 0, 24] + Array("ftypheic".utf8) +
            Array(repeating: UInt8(0), count: 8)
        )
        try body.write(to: unnamed)
        let staged = try FileMannShareFileNaming.stageForQueue(
            sourceURL: unnamed,
            suggestedName: "image.heic",
            typeIdentifier: UTType.heic.identifier,
            selectionIndex: 29,
            in: root
        )
        XCTAssertTrue(staged.lastPathComponent.hasSuffix(".heic"))
        XCTAssertEqual(
            FileMannShareFileNaming.readMetadata(
                for: staged
            )?.needsFilenameDecision,
            true
        )
        XCTAssertEqual(try Data(contentsOf: staged), body)
    }

    func testLegacyArchiveTaskDecodesWithoutReceiptFields() throws {
        let task = ArchiveTask(
            bookmark: Data(),
            displayName: "shared-media.mp4",
            remoteFileName: "shared-media.mp4",
            fileSize: 10,
            sourceModifiedAt: nil
        )
        let data = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(ArchiveTask.self, from: data)
        XCTAssertNil(restored.verifiedAt)
        XCTAssertNil(restored.remoteEndpointURL)
        XCTAssertNil(restored.attemptedRemotePath)
        XCTAssertNil(restored.completionKind)
        XCTAssertEqual(
            restored.completionDescription,
            restored.state.title
        )
    }

}
