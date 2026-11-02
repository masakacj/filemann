import Foundation
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
