import Foundation

/// Resolves the same sandbox container in the main app and Share Extension.
///
/// Sideloaded / self-signed provisioning profiles may have a different App
/// Group identifier than the development build. Read the groups advertised by
/// the embedded profile and use an accessible group, instead of hardcoding a
/// particular purchased certificate's identifier in source code.
enum FileMannShareGroup {
    enum StorageError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "签名未提供主 App 与分享扩展共同可访问的 App Group。请检查两者的描述文件和签名权限。"
        }
    }

    private static let debugGroup = "group.com.masakacj.filemann"
    private static let inboxRelativePath = "FileMann/Incoming-Share"

    static func sharedContainer() -> URL? {
        for groupID in availableGroupIdentifiers() {
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID
            ) {
                return url
            }
        }
        return nil
    }

    static func incomingDirectory(
        createIfMissing: Bool = true
    ) throws -> URL {
        guard let container = sharedContainer() else {
            throw StorageError.unavailable
        }
        let directory = container.appendingPathComponent(
            inboxRelativePath, isDirectory: true
        )
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    /// Do not expose a fixed, profile-specific ID in the public repo.
    /// Both app and extension are provisioned with the same profile.
    private static func availableGroupIdentifiers() -> [String] {
        let profileGroups = embeddedProvisioningGroups()
        return (profileGroups.sorted(by: >) + [debugGroup]).reduce(into: []) {
            (unique: inout [String], group: String) in
            if !unique.contains(group) {
                unique.append(group)
            }
        }
    }

    private static func embeddedProvisioningGroups() -> [String] {
        guard let url = Bundle.main.url(
            forResource: "embedded", withExtension: "mobileprovision"
        ),
        let data = try? Data(contentsOf: url),
        let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
        let end = data.range(of: Data("</plist>".utf8))?.upperBound,
        start < end else {
            return []
        }

        // The mobileprovision is CMS-wrapped; only inspect the embedded XML.
        let fragment = Data(data[start..<end])
        guard let profile = try? PropertyListSerialization.propertyList(
            from: fragment, format: nil
        ) as? [String: Any],
        let entitlements = profile["Entitlements"] as? [String: Any],
        let groups = entitlements[
            "com.apple.security.application-groups"
        ] as? [String] else {
            return []
        }
        return groups.filter { $0.hasPrefix("group.") }
    }
}
