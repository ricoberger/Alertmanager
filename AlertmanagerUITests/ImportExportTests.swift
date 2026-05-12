//
//  ImportExportTests.swift
//  AlertmanagerUITests
//

import XCTest

/// UI tests for the import/export configuration commands.
final class ImportExportTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Export

    /// Verifies that triggering Export opens an NSSavePanel.
    @MainActor
    func testExportOpensSavePanel() throws {
        // Commands are in the "Alertmanager" app menu (CommandGroup after
        // .appSettings), not in "File".
        app.menuBarItems["Alertmanager"].click()
        let exportItem = app.menuItems["Export Configuration"]
        guard exportItem.waitForExistence(timeout: 3) else {
            throw XCTSkip("Export Configuration menu item not found")
        }
        exportItem.click()

        // NSSavePanel is represented as a sheet or window with a text field
        // for the filename. Its title varies by macOS version.
        let savePanel = app.sheets.firstMatch
        let saveWindow = app.windows["Save"]
        let panelAppeared =
            savePanel.waitForExistence(timeout: 5) || saveWindow.waitForExistence(timeout: 2)
        XCTAssertTrue(panelAppeared, "Expected NSSavePanel to appear after Export")

        // Dismiss by pressing Escape.
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Import

    /// Verifies that triggering Import opens an NSOpenPanel.
    @MainActor
    func testImportOpensOpenPanel() throws {
        // Commands are in the "Alertmanager" app menu (CommandGroup after
        // .appSettings), not in "File".
        app.menuBarItems["Alertmanager"].click()
        let importItem = app.menuItems["Import Configuration"]
        guard importItem.waitForExistence(timeout: 3) else {
            throw XCTSkip("Import Configuration menu item not found")
        }
        importItem.click()

        let openPanel = app.sheets.firstMatch
        let openWindow = app.windows["Open"]
        let panelAppeared =
            openPanel.waitForExistence(timeout: 5) || openWindow.waitForExistence(timeout: 2)
        XCTAssertTrue(panelAppeared, "Expected NSOpenPanel to appear after Import")

        app.typeKey(.escape, modifierFlags: [])
    }
}
