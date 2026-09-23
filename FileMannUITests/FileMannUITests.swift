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
        let center = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.5,
                dy: 0.50
            )
        )
        center.tap()

        let progress = app.otherElements[
            "video-progress-overlay"
        ]
        XCTAssertTrue(
            progress.waitForExistence(timeout: 2),
            "播放操作后应显示进度条"
        )

        let right = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.82,
                dy: 0.48
            )
        )
        right.press(forDuration: 0.7)

        XCTAssertTrue(
            app.staticTexts["逐帧前进"]
                .waitForExistence(timeout: 2),
            "长按右侧应进入逐帧前进"
        )
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
        let thumbnail = app.otherElements[
            "remote-thumbnail-\(name)"
        ]
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
