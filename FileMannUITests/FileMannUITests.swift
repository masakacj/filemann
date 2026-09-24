import XCTest

final class FileMannUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsSheetStaysPresentedOnFirstOpen() {
        let app = XCUIApplication()
        configureBaseEnvironment(app)
        app.launch()

        let settingsButton = app.buttons["设置"].firstMatch
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 5)
        )

        settingsButton.tap()

        let settingsBar = app.navigationBars["设置"]
        XCTAssertTrue(
            settingsBar.waitForExistence(timeout: 3)
        )

        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(
            settingsBar.exists,
            "设置页第一次打开后不应自动退回"
        )

        app.buttons["取消"].tap()
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 3)
        )

        settingsButton.tap()
        XCTAssertTrue(
            settingsBar.waitForExistence(timeout: 3)
        )
    }

    func testLocalLibraryUsesExternalFolderWorkflow() {
        let app = XCUIApplication()
        configureBaseEnvironment(app)
        app.launch()

        XCTAssertFalse(
            app.buttons["从相册导入"].exists,
            "本地媒体页不应再显示从相册导入按钮"
        )

        let moreButton = app.buttons[
            "media-library-more-menu"
        ].firstMatch
        XCTAssertTrue(
            moreButton.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            moreButton.isHittable,
            "更多菜单按钮应可点击"
        )

        // XCUIElement.tap() may first issue an accessibility
        // scroll-to-visible action for navigation-bar items. On the
        // simulator this intermittently returns kAXErrorCannotComplete
        // even though the button is already visible. Tapping the
        // element's center coordinate exercises the same real UI
        // without that flaky pre-scroll action.
        moreButton.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: 0.5
            )
        ).tap()

        XCTAssertTrue(
            app.buttons["映射外部文件夹"]
                .waitForExistence(timeout: 3),
            "更多菜单应提供外部文件夹映射入口"
        )

        XCTAssertFalse(
            app.switches[
                "FileMann 导入后清理相册原件"
            ].exists
        )
        XCTAssertFalse(
            app.switches[
                "快捷指令复制后询问删除相册原件"
            ].exists
        )
    }

    func testLocalWebDAVIsPreferredAndThumbnailsLoad() {
        let app = XCUIApplication()
        configureBaseEnvironment(app)

        app.launchEnvironment["FILEMANN_TEST_LOCAL_TITLE"] =
            "CI Local"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HOST"] =
            "127.0.0.1"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_PORT"] =
            "8765"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HTTPS"] =
            "0"

        app.launchEnvironment["FILEMANN_TEST_REMOTE_TITLE"] =
            "CI Remote"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_HOST"] =
            "127.0.0.1"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_PORT"] =
            "8766"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_HTTPS"] =
            "1"
        app.launchEnvironment[
            "FILEMANN_TEST_REMOTE_ALLOW_INVALID_CERT"
        ] = "1"

        app.launch()
        app.tabBars.buttons["NAS"].tap()

        XCTAssertTrue(
            app.staticTexts["CI Local"]
                .waitForExistence(timeout: 8)
        )
        assertMockMediaVisible(app)
        assertThumbnailLoads(
            app,
            name: "photo.jpg"
        )
        assertThumbnailLoads(
            app,
            name: "clip.mp4"
        )
    }

    func testRemoteFallbackWorksWithSelfSignedHTTPS() {
        let app = XCUIApplication()
        configureBaseEnvironment(app)

        app.launchEnvironment["FILEMANN_TEST_LOCAL_TITLE"] =
            "CI Local"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HOST"] =
            "127.0.0.1"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_PORT"] =
            "65533"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HTTPS"] =
            "0"

        app.launchEnvironment["FILEMANN_TEST_REMOTE_TITLE"] =
            "CI Remote"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_HOST"] =
            "127.0.0.1"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_PORT"] =
            "8766"
        app.launchEnvironment["FILEMANN_TEST_REMOTE_HTTPS"] =
            "1"
        app.launchEnvironment[
            "FILEMANN_TEST_REMOTE_ALLOW_INVALID_CERT"
        ] = "1"

        app.launch()
        app.tabBars.buttons["NAS"].tap()

        XCTAssertTrue(
            app.staticTexts["CI Remote"]
                .waitForExistence(timeout: 10)
        )
        assertMockMediaVisible(app)
        assertThumbnailLoads(
            app,
            name: "photo.jpg"
        )
        assertThumbnailLoads(
            app,
            name: "clip.mp4"
        )
    }

    func testVideoProgressAppearsAfterGesture() {
        let app = XCUIApplication()
        configureBaseEnvironment(app)

        app.launchEnvironment["FILEMANN_TEST_LOCAL_TITLE"] =
            "CI Local"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HOST"] =
            "127.0.0.1"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_PORT"] =
            "8765"
        app.launchEnvironment["FILEMANN_TEST_LOCAL_HTTPS"] =
            "0"

        app.launch()
        app.tabBars.buttons["NAS"].tap()

        let clip = app.staticTexts["clip.mp4"]
        XCTAssertTrue(
            clip.waitForExistence(timeout: 8)
        )
        clip.tap()

        XCTAssertTrue(
            app.buttons["完成"]
                .waitForExistence(timeout: 8)
        )

        let window = app.windows.element(boundBy: 0)
        let right = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.82,
                dy: 0.48
            )
        )

        // Start from the paused beginning. A single right-side tap
        // advances one frame and should reveal the transient progress UI.
        right.tap()

        let progress = app
            .descendants(matching: .any)
            .matching(
                identifier: "video-progress-overlay"
            )
            .firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 2),
            "逐帧操作后应显示进度条"
        )

        let before = progressTime(progress)

        // Keep stepping forward while held. Because the clip is only
        // about one second long, do not start normal playback first or
        // the test can already be sitting at EOF.
        right.press(forDuration: 0.45)

        XCTAssertTrue(
            progress.waitForExistence(timeout: 2)
        )
        let after = progressTime(progress)

        XCTAssertGreaterThan(
            after,
            before,
            "长按右侧应连续逐帧前进并实时更新时间"
        )

        Thread.sleep(forTimeInterval: 5.4)
        XCTAssertFalse(
            progress.exists,
            "5 秒无操作后进度条应自动隐藏"
        )
    }

    private func progressTime(
        _ element: XCUIElement
    ) -> Double {
        guard let value = element.value as? String else {
            return 0
        }

        for component in value.split(separator: ";") {
            let pair = component.split(
                separator: "=",
                maxSplits: 1
            )
            if pair.count == 2,
               pair[0] == "current",
               let number = Double(pair[1]) {
                return number
            }
        }

        return 0
    }

    private func configureBaseEnvironment(
        _ app: XCUIApplication
    ) {
        app.launchEnvironment["FILEMANN_UI_TEST"] = "1"
        app.launchEnvironment["FILEMANN_UI_TEST_RESET"] = "1"
        app.launchEnvironment["FILEMANN_TEST_WEBDAV_USER"] =
            "filemann"
        app.launchEnvironment[
            "FILEMANN_TEST_WEBDAV_PASSWORD"
        ] = "filemann-pass"
    }

    private func assertMockMediaVisible(
        _ app: XCUIApplication
    ) {
        XCTAssertTrue(
            app.staticTexts["Album"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["photo.jpg"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["clip.mp4"]
                .waitForExistence(timeout: 5)
        )
    }

    private func assertThumbnailLoads(
        _ app: XCUIApplication,
        name: String
    ) {
        let thumbnail = app
            .descendants(matching: .any)
            .matching(
                identifier: "remote-thumbnail-\(name)"
            )
            .firstMatch
        XCTAssertTrue(
            thumbnail.waitForExistence(timeout: 5)
        )

        let loaded = NSPredicate(
            format: "value == %@",
            "loaded"
        )
        expectation(
            for: loaded,
            evaluatedWith: thumbnail
        )
        waitForExpectations(timeout: 10)
    }
}
