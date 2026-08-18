import AppKit
import XCTest

final class LaunchReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchReadinessFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--ui-select-destination=workspace:pokeos-api"]
        app.launch()
        app.activate()

        let workspaceButton = app.buttons.matching(identifier: "sidebar-workspace-pokeos-api").firstMatch
        XCTAssertTrue(workspaceButton.waitForExistence(timeout: 5))

        // Rows are `List` cells rather than buttons since 1.2.0 — that is what buys arrow-key
        // navigation and shift-click ranges — so the query must not assume an element type.
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "item-row-primary-postgres")
            .firstMatch
            .waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "item-row-edge-storage")
            .firstMatch
            .exists)

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 2))
        app.activate()
        fileMenu.click()
        let newItemMenuItem = app.menuItems["New Secret Item…"]
        XCTAssertTrue(newItemMenuItem.waitForExistence(timeout: 2))
        newItemMenuItem.click()

        // One page now: the name field is there the moment the sheet opens, and the kind is a
        // control on the form rather than a gallery you have to get through first.
        XCTAssertTrue(app.textFields.matching(identifier: "editor-title-field").firstMatch.waitForExistence(timeout: 2))
        // Matched by identifier without pinning an element type: a SwiftUI `Menu` surfaces as a
        // pop-up or a menu button depending on the release, and the test should not care which.
        for identifier in ["editor-workspace-picker", "editor-environment-picker", "editor-item-type-picker"] {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
                "expected \(identifier) on the creation sheet"
            )
        }
        XCTAssertTrue(app.textFields.matching(identifier: "editor-new-field-name").firstMatch.exists)
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

        copyFeedbackApp.activate()
        NSPasteboard.general.clearContents()
        copyFeedbackApp.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForPasteboardString(containing: "# Primary Postgres", timeout: 2))
        XCTAssertTrue(waitForPasteboardString(containing: "HOST=db.pokeos.internal", timeout: 2))
        copyFeedbackApp.terminate()
    }

    func testCommandPaletteOpensWithShortcutAndDismisses() throws {
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
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        XCTAssertTrue(search.waitForNonExistence(timeout: 2))
    }

    private func waitForPasteboardString(containing fragment: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = NSPasteboard.general.string(forType: .string), value.contains(fragment) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }
}
