//
//  ImportExportRoundTripTests.swift
//  AlertmanagerUITests
//

import XCTest

/// End-to-end test of the export → reset → import flow.
///
/// Exercises the real `ImportExportManager` code path: a configuration is
/// serialized to a real JSON file on disk, the store is wiped via the
/// Reset Configuration menu command, and the file is then re-imported.
/// The NSSavePanel / NSOpenPanel UI is bypassed via the
/// `-uiTestExportPath` / `-uiTestImportPath` launch arguments so the test
/// doesn't have to drive a system file dialog, and the initial
/// alertmanager is created via `-uiTestSeedAlertmanagerURL` to avoid
/// driving the Add Alertmanager form (which was flaky on CI macOS runners).
final class ImportExportRoundTripTests: XCTestCase {
    var app: XCUIApplication!
    /// Unique JSON file path used as both the export target and the
    /// subsequent import source. Lives in the test runner's temp dir,
    /// which the unsandboxed app can write to and the test can read.
    var roundTripPath: URL!

    /// Name of the seeded alertmanager — must match the constant used by
    /// `seedFromLaunchArgumentsIfNeeded` in `AlertmanagerApp.swift`.
    let seededName = "Test AM"
    let seededURL = "http://localhost:9093"

    override func setUpWithError() throws {
        continueAfterFailure = false
        roundTripPath = FileManager.default.temporaryDirectory.appending(
            path: "Alertmanager-RoundTrip-\(UUID().uuidString).json")

        app = XCUIApplication()
        app.launchArguments += ["-uiTestResetStore"]
        // URL/path-shaped values travel via the environment instead of
        // `launchArguments`. macOS 26 parses `-key value` argument pairs
        // into `NSUserDefaults`, and URL/path-typed entries in that table
        // prevent the app's main window from appearing at all.
        app.launchEnvironment["UI_TEST_SEED_ALERTMANAGER_URL"] = seededURL
        app.launchEnvironment["UI_TEST_EXPORT_PATH"] = roundTripPath.path
        app.launchEnvironment["UI_TEST_IMPORT_PATH"] = roundTripPath.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let path = roundTripPath {
            try? FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Helpers

    private func openAlertmanagerMenu() {
        app.menuBarItems["Alertmanager"].click()
    }

    // MARK: - Round trip

    @MainActor
    func testExportResetImportRoundTrip() throws {
        // 1. The seed inserted a `Test AM` row at app launch. Wait for
        // the corresponding sidebar entry so subsequent assertions have
        // a stable target to track across reset and import.
        let sidebarRow = app.descendants(matching: .button).matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-alertmanager-name-\(seededName)'")
        ).firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10))

        // 2. Trigger Export — app writes the JSON file directly to
        // `roundTripPath` because of `-uiTestExportPath`.
        openAlertmanagerMenu()
        app.menuItems["Export Configuration"].click()

        let exportedAt = expectFileExists(at: roundTripPath, timeout: 5)
        XCTAssertNotNil(exportedAt, "Export file was never written to \(roundTripPath.path)")

        // Sanity-check the file is a valid JSON document containing the
        // seeded alertmanager.
        let exportData = try Data(contentsOf: roundTripPath)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exportData) as? [String: Any])
        let alertmanagers = try XCTUnwrap(json["alertmanagers"] as? [[String: Any]])
        XCTAssertEqual(alertmanagers.count, 1)
        XCTAssertEqual(alertmanagers.first?["name"] as? String, seededName)
        XCTAssertEqual(alertmanagers.first?["url"] as? String, seededURL)

        // 3. Trigger Reset and confirm the destructive action.
        openAlertmanagerMenu()
        app.menuItems["Reset Configuration"].click()

        // The confirmation dialog renders the destructive button as
        // "Reset". macOS also surfaces a same-labeled control on the
        // TouchBar, so match on the sheet's `action-button-1`
        // identifier instead — that's the system-assigned id for the
        // first non-cancel button in an alert/confirmation sheet.
        let resetButton = app.sheets.firstMatch.buttons["action-button-1"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5))
        resetButton.click()

        // The sidebar row must disappear after reset.
        XCTAssertTrue(sidebarRow.waitForNonExistence(timeout: 5))

        // 4. Trigger Import — app reads from `roundTripPath` because of
        // `-uiTestImportPath`.
        openAlertmanagerMenu()
        app.menuItems["Import Configuration"].click()

        // Dismiss the "Import Complete" success alert. Same TouchBar
        // duplicate caveat applies — scope to the sheet.
        let okButton = app.sheets.firstMatch.buttons["action-button-1"]
        XCTAssertTrue(okButton.waitForExistence(timeout: 5))
        okButton.click()

        // The previously-seeded row should reappear from the imported JSON.
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    /// Polls `FileManager` for the given path. Returns the modification
    /// date if the file appeared within `timeout`, otherwise `nil`.
    private func expectFileExists(at url: URL, timeout: TimeInterval) -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
                    as? Date ?? Date()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}
