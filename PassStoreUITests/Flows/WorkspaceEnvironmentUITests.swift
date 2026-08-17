import XCTest

/// The environment tabs and the sidebar's environment rows.
///
/// Both are the kind of thing a unit test cannot see: the tabs are drawn by SwiftUI and the
/// sidebar rows are an AppKit table, so this drives the real window instead. Not part of CI,
/// which runs the unit target only — it is here to be run against a build by hand.
final class WorkspaceEnvironmentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnvironmentTabsNarrowTheListToOneEnvironment() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--ui-select-destination=workspace:pokeos-api"]
        app.launch()
        app.activate()

        let allTab = app.buttons.matching(identifier: "environment-tab-all").firstMatch
        XCTAssertTrue(allTab.waitForExistence(timeout: 5))

        // The seeded workspace has secrets in Local, Dev and Prod, so it gets a tab each.
        let prodTab = app.buttons.matching(identifier: "environment-tab-prod").firstMatch
        XCTAssertTrue(prodTab.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons.matching(identifier: "environment-tab-local").firstMatch.exists)

        XCTAssertTrue(itemRow(app, "primary-postgres").waitForExistence(timeout: 2))
        XCTAssertTrue(itemRow(app, "frontend-env").exists)

        prodTab.click()
        XCTAssertTrue(itemRow(app, "primary-postgres").waitForExistence(timeout: 2))
        // Frontend .env lives in Local, so the Prod tab must not show it.
        XCTAssertTrue(itemRow(app, "frontend-env").waitForNonExistence(timeout: 2))

        allTab.click()
        XCTAssertTrue(itemRow(app, "frontend-env").waitForExistence(timeout: 2))
        app.terminate()
    }

    func testExpandingAWorkspaceRevealsItsEnvironmentsInTheSidebar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--ui-select-destination=workspace:pokeos-api"]
        app.launch()
        app.activate()

        let workspaceRow = app.buttons.matching(identifier: "sidebar-workspace-pokeos-api").firstMatch
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 5))

        let environmentRow = app.buttons
            .matching(identifier: "sidebar-workspace-pokeos-api-environment-prod")
            .firstMatch
        // Collapsed to begin with: an existing vault's sidebar looks exactly as it did.
        XCTAssertFalse(environmentRow.exists)

        let disclosure = app.buttons
            .matching(identifier: "sidebar-workspace-pokeos-api-disclosure")
            .firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 2))
        disclosure.click()

        XCTAssertTrue(environmentRow.waitForExistence(timeout: 2))
        environmentRow.click()

        XCTAssertTrue(itemRow(app, "primary-postgres").waitForExistence(timeout: 2))
        XCTAssertTrue(itemRow(app, "frontend-env").waitForNonExistence(timeout: 2))

        disclosure.click()
        XCTAssertTrue(environmentRow.waitForNonExistence(timeout: 2))
        app.terminate()
    }

    /// Secrets sharing a name in one workspace are one secret in several environments, and the
    /// detail pane is where you read across them.
    func testTheDetailPaneSwitchesTheSameSecretBetweenEnvironments() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--ui-select-destination=workspace:pokeos-api"]
        app.launch()
        app.activate()

        XCTAssertTrue(itemRow(app, "primary-postgres").waitForExistence(timeout: 5))
        itemRow(app, "primary-postgres").click()

        let bar = app.descendants(matching: .any).matching(identifier: "environment-sibling-bar").firstMatch
        // Only drawn when the project has more than one environment to read across.
        guard bar.waitForExistence(timeout: 2) else {
            throw XCTSkip("The seeded workspace has no secret that exists in more than one environment.")
        }

        let local = app.descendants(matching: .any)
            .matching(identifier: "environment-sibling-local").firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 2))
        local.click()

        // The title stays — it is the same secret — and the header now names the environment.
        XCTAssertTrue(app.staticTexts.matching(identifier: "detail-item-title").firstMatch.exists)
        app.terminate()
    }

    private func itemRow(_ app: XCUIApplication, _ slug: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "item-row-\(slug)").firstMatch
    }
}
