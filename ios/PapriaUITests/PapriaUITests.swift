import XCTest

final class PapriaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func testAppLaunches() {
        XCTAssertTrue(app.exists)
    }

    func testLocalLibraryShellKeepsCoreTabsAvailable() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8), "The local-first reader shell should become available after state restoration")
        let expectedTabs = ["书库", "BookOrbit", "传书", "设置"]
        let actualTabs = tabBar.buttons.allElementsBoundByIndex.map(\.label)

        XCTAssertEqual(
            actualTabs,
            expectedTabs,
            "0.1.0 requires exactly four system tabs in this order."
        )
        XCTAssertFalse(
            tabBar.buttons["下载任务"].exists,
            "下载任务 is a BookOrbit secondary destination, never a root tab."
        )
    }

    func testLibraryAndBookOrbitUseSeparateRootContexts() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))

        tabBar.buttons["书库"].tap()
        XCTAssertTrue(app.navigationBars["书库"].waitForExistence(timeout: 5))

        tabBar.buttons["BookOrbit"].tap()
        XCTAssertTrue(
            app.navigationBars["BookOrbit"].waitForExistence(timeout: 5),
            "BookOrbit must be its own root context rather than a section mixed into the local library."
        )

        // No catalog fixture is injected for UI tests: cached and authenticated
        // BookOrbit content is intentionally device state.  The two root
        // navigation contexts are the stable, data-independent separation
        // contract to assert here.
        tabBar.buttons["书库"].tap()
        XCTAssertTrue(app.navigationBars["书库"].waitForExistence(timeout: 5))
    }

    func testDownloadTasksAreOnlyReachableFromBookOrbit() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 8))
        XCTAssertFalse(tabBar.buttons["下载任务"].exists)

        tabBar.buttons["BookOrbit"].tap()
        let taskCenter = app.buttons["下载任务"]
        XCTAssertTrue(
            taskCenter.waitForExistence(timeout: 5),
            "The BookOrbit toolbar must expose the secondary download task center."
        )
    }

    func testWiFiTransferTabShowsLocalOnlySafetyGuidanceWithoutStartingService() {
        let transferTab = app.tabBars.buttons["传书"]
        XCTAssertTrue(transferTab.waitForExistence(timeout: 8))
        transferTab.tap()

        XCTAssertTrue(app.staticTexts["在同一 Wi-Fi 下传书"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["启动传书"].exists)
        XCTAssertTrue(app.staticTexts["传书安全说明：服务会保持运行，直到你选择停止。Wi-Fi 导入只保存到本机，不会上传 BookOrbit"].exists)
    }

    func testWiFiTransferRunningServiceExposesTextAddressAndCopyAction() throws {
        let transferTab = app.tabBars.buttons["传书"]
        XCTAssertTrue(transferTab.waitForExistence(timeout: 8))
        transferTab.tap()

        let startButton = app.buttons["启动传书"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        // The address value is deliberately a real local-network address,
        // not a test fixture.  Its accessibility value keeps the complete
        // text address available independently of the QR code.
        let address = app.staticTexts.matching(
            NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "局域网地址", "http")
        ).firstMatch
        if !address.waitForExistence(timeout: 12) {
            if app.staticTexts["传书服务不可用"].exists {
                throw XCTSkip("The current simulator has no usable local-network interface for the real Wi-Fi transfer service.")
            }
            XCTFail("Expected the running transfer service to expose a complete text address.")
            return
        }

        XCTAssertTrue(app.staticTexts["局域网地址"].exists)
        let addressValue = address.value as? String ?? ""
        XCTAssertTrue(addressValue.hasPrefix("http"), "The full LAN URL must be exposed as text, not only as a QR code.")

        let copyButton = app.buttons["复制局域网地址"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 3))
        copyButton.tap()
        XCTAssertTrue(app.staticTexts["地址已复制"].waitForExistence(timeout: 3))
    }

    func testSettingsShowsLocalFirstAndCredentialIsolationPolicy() {
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8))
        settingsTab.tap()

        for _ in 0..<3 where !app.staticTexts["v2.5.0"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["v2.5.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["服务器地址、账号和证书指纹保存在本地 SQLite；访问令牌和 refresh cookie 仅保存在 Keychain。"].exists)
    }
}
