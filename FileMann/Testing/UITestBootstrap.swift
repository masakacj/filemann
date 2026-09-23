import Foundation

enum UITestBootstrap {
    static func applyIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["FILEMANN_UI_TEST"] == "1" else {
            return
        }

        if env["FILEMANN_UI_TEST_RESET"] == "1",
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(
                forName: bundleID
            )
        }

        var settings = SMBSettings()
        settings.transport = .webDAV
        settings.webDAVUsername =
            env["FILEMANN_TEST_WEBDAV_USER"]
            ?? "filemann"
        settings.webDAVWiFiOnly = false
        settings.deleteAfterArchive = false

        settings.webDAVLocalTitle =
            env["FILEMANN_TEST_LOCAL_TITLE"]
            ?? "CI Local"
        settings.webDAVLocalHost =
            env["FILEMANN_TEST_LOCAL_HOST"]
            ?? ""
        settings.webDAVLocalPort =
            env["FILEMANN_TEST_LOCAL_PORT"]
            ?? ""
        settings.webDAVLocalPath =
            env["FILEMANN_TEST_LOCAL_PATH"]
            ?? "/"
        settings.webDAVLocalHTTPS =
            env["FILEMANN_TEST_LOCAL_HTTPS"]
            == "1"
        settings.webDAVLocalAllowInvalidCertificate =
            env["FILEMANN_TEST_LOCAL_ALLOW_INVALID_CERT"]
            == "1"

        settings.webDAVRemoteTitle =
            env["FILEMANN_TEST_REMOTE_TITLE"]
            ?? "CI Remote"
        settings.webDAVRemoteHost =
            env["FILEMANN_TEST_REMOTE_HOST"]
            ?? ""
        settings.webDAVRemotePort =
            env["FILEMANN_TEST_REMOTE_PORT"]
            ?? ""
        settings.webDAVRemotePath =
            env["FILEMANN_TEST_REMOTE_PATH"]
            ?? "/"
        settings.webDAVRemoteHTTPS =
            env["FILEMANN_TEST_REMOTE_HTTPS"]
            == "1"
        settings.webDAVRemoteAllowInvalidCertificate =
            env["FILEMANN_TEST_REMOTE_ALLOW_INVALID_CERT"]
            == "1"

        TaskStore.saveSettings(settings)

        let password =
            env["FILEMANN_TEST_WEBDAV_PASSWORD"]
            ?? "filemann-pass"
        try? KeychainStore.saveWebDAVPassword(password)
    }
}
