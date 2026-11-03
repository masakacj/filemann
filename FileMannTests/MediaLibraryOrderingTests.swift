import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import FileMann

final class MediaLibraryOrderingTests: XCTestCase {
    func testCameraOriginalFilenamesSortNaturallyWhenTimestampsTie() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let filenames = [
            "IMG_10.HEIC", "IMG_2.HEIC", "IMG_11.MOV", "IMG_1.JPG"
        ]
        let sameDate = Date(timeIntervalSince1970: 1_783_025_400)
        let items = try filenames.map { name -> MediaItem in
            let file = root.appendingPathComponent(name)
            try Data([0x00, 0x01, 0x02]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: sameDate], ofItemAtPath: file.path
            )
            return try XCTUnwrap(MediaItem(url: file))
        }
        XCTAssertEqual(items.map(\.modifiedAt).allSatisfy {
            abs($0.timeIntervalSince(sameDate)) < 1
        }, true)

        let expected = [
            "IMG_1.JPG", "IMG_2.HEIC", "IMG_10.HEIC", "IMG_11.MOV"
        ]

        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                items, by: .shootingNewest
            ).map(\.name),
            expected
        )
        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                Array(items.reversed()), by: .shootingNewest
            ).map(\.name),
            expected
        )
        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                items, by: .filenameAscending
            ).map(\.name),
            expected
        )
        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                items, by: .filenameDescending
            ).map(\.name),
            Array(expected.reversed())
        )
    }

    func testExifShootingDateOverridesSameExportModificationTime() throws {
        let folder = try testDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let earlier = folder.appendingPathComponent("IMG_99.JPG")
        let later = folder.appendingPathComponent("IMG_1.JPG")
        try makeJPEG(
            at: earlier, originalDate: "2024:03:01 09:00:00"
        )
        try makeJPEG(
            at: later, originalDate: "2024:03:02 12:30:00"
        )
        let sameExportTime = Date(timeIntervalSince1970: 1_783_025_400)
        for file in [earlier, later] {
            try FileManager.default.setAttributes(
                [.modificationDate: sameExportTime],
                ofItemAtPath: file.path
            )
        }

        let items = try [earlier, later].map {
            try XCTUnwrap(MediaItem(url: $0))
        }
        XCTAssertNotNil(items[0].capturedAt)
        XCTAssertNotNil(items[1].capturedAt)
        XCTAssertLessThan(items[0].preferredDate, items[1].preferredDate)
        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                items, by: .shootingNewest
            ).map(\.name),
            ["IMG_1.JPG", "IMG_99.JPG"]
        )
    }

    func testOriginalFileContentAndFilenamesAreNeverChangedByScan() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalName = "隐藏原片🌸 #1  (A).HEIC"
        let path = root.appendingPathComponent(originalName)
        let content = Data([0x00, 0x00, 0x00, 0x18] +
                           Array("ftypheic".utf8) +
                           Array(repeating: UInt8(0x01), count: 8))
        try content.write(to: path)

        let media = try XCTUnwrap(MediaItem(url: path))
        XCTAssertEqual(media.name, originalName)
        XCTAssertEqual(media.kind, .image)
        XCTAssertEqual(media.id, path.standardizedFileURL.path)
        XCTAssertEqual(media.fileSize, Int64(content.count))
        XCTAssertEqual(try Data(contentsOf: path), content)
    }

    func testAaeAndOtherCompanionFilesNeverBecomeGalleryTiles() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let companions = ["IMG_2001.AAE", "IMG_2001.XMP", "metadata.json"]
        let sources = companions + ["IMG_2001.HEIC", "IMG_2001.MOV"]
        for name in sources {
            try Data([0x01]).write(
                to: root.appendingPathComponent(name)
            )
        }
        let items = sources.compactMap { name in
            MediaItem(url: root.appendingPathComponent(name))
        }
        XCTAssertEqual(
            Set(items.map(\.name)),
            Set(["IMG_2001.HEIC", "IMG_2001.MOV"])
        )
    }

    func testIdenticalNamesHaveDeterministicPathTieBreaker() throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sameDate = Date(timeIntervalSince1970: 1_783_025_400)
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(
            at: a, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: b, withIntermediateDirectories: true
        )
        let urls = [a, b].map {
            $0.appendingPathComponent("IMG_2.HEIC")
        }
        for url in urls {
            try Data([0x11]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: sameDate], ofItemAtPath: url.path
            )
        }
        let items = try urls.map {
            try XCTUnwrap(MediaItem(url: $0))
        }
        XCTAssertEqual(
            MediaLibraryOrdering.sorted(
                items, by: .shootingNewest
            ).map(\.id),
            MediaLibraryOrdering.sorted(
                Array(items.reversed()), by: .shootingNewest
            ).map(\.id)
        )
    }

    private func makeJPEG(
        at url: URL, originalDate: String
    ) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.jpeg" as CFString,
                1, nil
            )
        )
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String:
                    originalDate
            ]
        ]
        CGImageDestinationAddImage(
            destination, image, metadata as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func testDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        return folder
    }
}
