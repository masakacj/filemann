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
}
