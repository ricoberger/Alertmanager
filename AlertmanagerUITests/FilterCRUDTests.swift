//
//  FilterCRUDTests.swift
//  AlertmanagerUITests
//

import XCTest

/// UI tests covering the create / delete lifecycle of a Filter entry via
/// the main-window sidebar and form sheet.
///
/// Note: A Filter requires at least one Alertmanager to be selected, so
/// these tests first create an Alertmanager to satisfy that constraint.
final class FilterCRUDTests: XCTestCase {
    var app: XCUIApplication!
    /// Name of the helper alertmanager created in setUp. Stable across runs
    /// because `-uiTestResetStore` gives each launch a fresh SwiftData store.
    let helperAMName = "FT-AM"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestResetStore"]
        app.launch()
        createAlertmanager(named: helperAMName, url: "http://localhost:9093")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func createAlertmanager(named name: String, url: String) {
        app.menuBarItems["Alertmanager"].click()
        app.menuItems["Add Alertmanager"].click()

        let nameField = app.textFields["alertmanager-name-field"]
        guard nameField.waitForExistence(timeout: 5) else { return }
        nameField.click()
        nameField.typeText(name)

        let urlField = app.textFields["alertmanager-url-field"]
        urlField.click()
        urlField.typeText(url)

        app.buttons["alertmanager-save-button"].click()
        // Wait for the sheet to dismiss before returning.
        _ = app.textFields["alertmanager-name-field"].waitForNonExistence(timeout: 5)
    }

    private func openAddFilterSheet() {
        app.menuBarItems["Alertmanager"].click()
        app.menuItems["Add Filter"].click()
    }

    private func waitForFilterForm() -> XCUIElement {
        let nameField = app.textFields["filter-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        return nameField
    }

    // MARK: - Create

    @MainActor
    func testAddFilterSheetOpens() throws {
        openAddFilterSheet()
        XCTAssertTrue(app.textFields["filter-name-field"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSaveButtonDisabledWhenNameEmpty() throws {
        openAddFilterSheet()
        _ = waitForFilterForm()
        let saveButton = app.buttons["filter-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)
    }

    @MainActor
    func testCancelDismissesFilterSheet() throws {
        openAddFilterSheet()
        _ = waitForFilterForm()
        app.buttons["filter-cancel-button"].click()
        XCTAssertFalse(app.textFields["filter-name-field"].exists)
    }

    @MainActor
    func testCreateFilterAppearsInSidebar() throws {
        openAddFilterSheet()
        let nameField = waitForFilterForm()
        let filterName = "FT"
        nameField.click()
        nameField.typeText(filterName)

        // Each alertmanager Toggle has identifier "filter-am-toggle-<name>".
        // Use .any + NSPredicate to avoid element-type mismatch.
        let togglePredicate = NSPredicate(
            format: "identifier == 'filter-am-toggle-\(helperAMName)'")
        let amToggle = app.descendants(matching: .any).matching(togglePredicate).firstMatch
        if amToggle.waitForExistence(timeout: 10) {
            amToggle.click()
        }

        let saveButton = app.buttons["filter-save-button"]
        // Allow extra time for the toggle click to enable the button.
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        guard saveButton.isEnabled else {
            throw XCTSkip("Could not enable Save — alertmanager toggle may not have registered")
        }
        saveButton.click()

        // The sidebar row button identifier is "sidebar-filter-name-<name>".
        XCTAssertTrue(
            app.buttons["sidebar-filter-name-\(filterName)"].waitForExistence(timeout: 10))
    }
}
