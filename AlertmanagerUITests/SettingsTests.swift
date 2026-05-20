//
//  SettingsTests.swift
//  AlertmanagerUITests
//

import XCTest

/// UI tests for the Settings window (⌘,).
final class SettingsTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestResetStore"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func openSettings() -> XCUIElement {
        app.menuBarItems["Alertmanager"].click()
        app.menuItems["Settings…"].click()
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        return settingsWindow
    }

    // MARK: - Tests

    @MainActor
    func testSettingsWindowOpens() throws {
        let win = openSettings()
        XCTAssertTrue(win.popUpButtons["settings-refresh-interval-picker"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMenuBarEnabledToggleExists() throws {
        _ = openSettings()
        // SwiftUI Toggle in a macOS Form renders as type 40 (XCUIElementType.toggle).
        // Query using .any + identifier predicate to avoid element-type mismatch.
        let predicate = NSPredicate(format: "identifier == 'settings-menu-bar-enabled-toggle'")
        let toggle = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
    }

    @MainActor
    func testShowAlertmanagerNameToggleExists() throws {
        _ = openSettings()
        let predicate = NSPredicate(format: "identifier == 'settings-show-alertmanager-name-toggle'")
        let toggle = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
    }
}
