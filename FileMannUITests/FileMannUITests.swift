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

        let progress = app
            .descendants(matching: .any)
            .matching(
                identifier: "video-progress-overlay"
            )
            .firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 2),
            "播放操作后应显示进度条"
        )

        // Pause before frame stepping so the time delta comes
        // from the frame-step gesture rather than normal playback.
        center.tap()
        let before = progressTime(progress)

        let right = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: 0.82,
                dy: 0.48
            )
        )
        right.press(forDuration: 0.7)

        XCTAssertTrue(
            progress.waitForExistence(timeout: 2)
        )
        let after = progressTime(progress)

        XCTAssertGreaterThan(
            after,
            before,
            "长按右侧应逐帧前进并实时更新画面/时间"
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
