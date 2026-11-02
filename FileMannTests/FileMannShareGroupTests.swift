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
    func testPhotosSourceFilenameOverridesGenericSuggestedName() {
        XCTAssertEqual(
            FileMannShareFileNaming.preferredName(
                suggestedName: "shared-media.mp4",
                sourceFilename: "IMG_3847.MOV",
                typeIdentifier: "com.apple.quicktime-movie"
            ),
            "IMG_3847.MOV"
        )
        XCTAssertEqual(
            FileMannShareFileNaming.preferredName(
                suggestedName: "IMG_1024",
                sourceFilename: "IMG_1024.HEIC",
                typeIdentifier: "public.heic"
            ),
            "IMG_1024.HEIC"
        )
    }

    func testPhotosPreferredNameIsKeptWhenAvailable() {
        XCTAssertEqual(
            FileMannShareFileNaming.preferredName(
                suggestedName: "旅行 视频 01.MP4",
                sourceFilename: "temporary-file.mp4",
                typeIdentifier: "public.mpeg-4"
            ),
            "旅行 视频 01.MP4"
        )
    }

    func testGenericProviderNameUsesUniqueReadableFallback() {
        let first = FileMannShareFileNaming.preferredName(
            suggestedName: "shared-media.mp4",
            sourceFilename: "shared-media.mp4",
            typeIdentifier: "public.mpeg-4",
            now: Date(timeIntervalSince1970: 0),
            token: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000000")!
        )
        let next = FileMannShareFileNaming.preferredName(
            suggestedName: "shared-media.mp4",
            sourceFilename: "shared-media.mp4",
            typeIdentifier: "public.mpeg-4",
            now: Date(timeIntervalSince1970: 0),
            token: UUID(uuidString: "BBBB0000-0000-0000-0000-000000000000")!
        )
        XCTAssertTrue(first.hasPrefix("VID_"))
        XCTAssertTrue(first.hasSuffix(".mp4"))
        XCTAssertNotEqual(first, next)
        XCTAssertFalse(first.contains("shared-media"))
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
