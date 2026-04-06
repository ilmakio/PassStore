import XCTest

final class LaunchReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchReadinessFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.activate()

        let workspaceButton = app.buttons.matching(identifier: "sidebar-workspace-pokeos-api").firstMatch
        XCTAssertTrue(workspaceButton.waitForExistence(timeout: 5))
        app.activate()
        workspaceButton.click()

        XCTAssertTrue(app.buttons.matching(identifier: "item-row-primary-postgres").firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons.matching(identifier: "item-row-edge-storage").firstMatch.exists)

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 2))
        app.activate()
        fileMenu.click()
        let newItemMenuItem = app.menuItems["New Secret Item…"]
        XCTAssertTrue(newItemMenuItem.waitForExistence(timeout: 2))
        newItemMenuItem.click()

        let databaseTemplateCard = app.buttons.matching(identifier: "template-card-Database").firstMatch
        XCTAssertTrue(databaseTemplateCard.waitForExistence(timeout: 2))
        databaseTemplateCard.click()
        XCTAssertTrue(app.textFields.matching(identifier: "editor-title-field").firstMatch.waitForExistence(timeout: 2))
        app.buttons["Cancel"].firstMatch.click()
        app.terminate()

        let emptyFieldApp = XCUIApplication()
        emptyFieldApp.launchArguments = ["--uitesting", "--ui-select-item=ssh-optional-empty"]
        emptyFieldApp.launch()
        emptyFieldApp.activate()
        XCTAssertTrue(
            emptyFieldApp.scrollViews
                .matching(identifier: "detail-item-ssh-optional-empty")
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            emptyFieldApp.buttons
                .matching(identifier: "detail-field-value-privateKey")
                .firstMatch
                .exists
        )
        emptyFieldApp.terminate()

        let copyFeedbackApp = XCUIApplication()
        copyFeedbackApp.launchArguments = ["--uitesting", "--ui-select-item=primary-postgres"]
        copyFeedbackApp.launch()
        copyFeedbackApp.activate()
        XCTAssertTrue(
            copyFeedbackApp.scrollViews
                .matching(identifier: "detail-item-primary-postgres")
                .firstMatch
                .waitForExistence(timeout: 5)
        )

        let copyMenuButton = copyFeedbackApp.buttons["Copy"].firstMatch
        XCTAssertTrue(copyMenuButton.waitForExistence(timeout: 5))
        copyFeedbackApp.activate()
        copyMenuButton.click()
        let copyEnvItem = copyFeedbackApp.menuItems["Copy .env"].firstMatch
        XCTAssertTrue(copyEnvItem.waitForExistence(timeout: 3))
        copyEnvItem.click()
        copyFeedbackApp.terminate()
    }

    func testCommandPaletteOpensWithShortcutAndDismissesViaScrim() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.activate()

        let workspaceButton = app.buttons.matching(identifier: "sidebar-workspace-pokeos-api").firstMatch
        XCTAssertTrue(workspaceButton.waitForExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)

        let search = app.textFields.matching(identifier: "command-palette-search").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 2))

        let scrim = app.buttons.matching(identifier: "command-palette-scrim").firstMatch
        XCTAssertTrue(scrim.waitForExistence(timeout: 2))
        scrim.click()

        XCTAssertTrue(search.waitForNonExistence(timeout: 2))
    }
}
