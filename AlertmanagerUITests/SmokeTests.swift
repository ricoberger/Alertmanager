//
//  SmokeTests.swift
//  AlertmanagerUITests
//

import XCTest

/// Smoke tests that verify the app launches and the core skeleton of the
/// main window is present. These tests do not depend on any live
/// Alertmanager backend.
final class SmokeTests: XCTestCase {
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

    // MARK: - Launch

    @MainActor
    func testAppLaunches() throws {
        // The sidebar list must be present immediately after launch.
        let sidebar = app.outlines["sidebar-list"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSidebarSectionsExist() throws {
        // Both section headers must be visible.
        XCTAssertTrue(app.staticTexts["Filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alertmanagers"].exists)
    }
}
