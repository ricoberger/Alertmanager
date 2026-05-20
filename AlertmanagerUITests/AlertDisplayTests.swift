//
//  AlertDisplayTests.swift
//  AlertmanagerUITests
//

import XCTest

/// UI tests that exercise the alert-fetching and display path end to end
/// against a loopback `FakeAlertmanagerServer`, so the sidebar count
/// badge, the empty / error states, and the `AlertRowView` itself are
/// covered without depending on a real Alertmanager backend.
final class AlertDisplayTests: XCTestCase {
    var app: XCUIApplication!
    var server: FakeAlertmanagerServer!

    override func tearDownWithError() throws {
        server?.stop()
        app?.terminate()
    }

    // MARK: - Helpers

    /// Boots the fake server with `response`, launches the app pointed at
    /// it with a freshly-seeded `Test AM` row, and returns the launched
    /// application.
    private func launchWithFakeServer(response: FakeAlertmanagerServer.Response) throws
        -> XCUIApplication
    {
        server = try FakeAlertmanagerServer(response: response)
        try server.start()

        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestResetStore",
            "-uiTestSeedAlertmanagerURL", server.baseURL,
        ]
        app.launch()
        self.app = app
        return app
    }

    /// Returns the sidebar row button for the seeded `Test AM` alertmanager,
    /// waiting up to 10s for it to appear.
    private func seededSidebarRow() -> XCUIElement {
        // SwiftUI merges child accessibility identifiers into the row's
        // Button, so the button's identifier is a prefix-match rather than
        // an exact match.
        let row = app.descendants(matching: .button).matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-alertmanager-name-Test AM'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        return row
    }

    /// Waits until the sidebar row's accessibility label satisfies
    /// `predicate`, polling once a second.
    private func waitForRowLabel(
        _ row: XCUIElement, matching predicate: (String) -> Bool, timeout: TimeInterval = 10
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabel = row.label
        while Date() < deadline {
            lastLabel = row.label
            if predicate(lastLabel) { return lastLabel }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return predicate(lastLabel) ? lastLabel : nil
    }

    // MARK: - Populated

    @MainActor
    func testWatchdogAlertRenders() throws {
        _ = try launchWithFakeServer(
            response: .alerts(json: FakeAlertmanagerPayloads.watchdog))
        let row = seededSidebarRow()
        row.click()

        // SwiftUI propagates the `alert-row-Watchdog` accessibility identifier
        // (set on the row's outer VStack) down to every static text inside
        // the row. Match against any of those texts via the staticTexts
        // query, which has reliable wait semantics.
        let rowText = app.staticTexts.matching(identifier: "alert-row-Watchdog").firstMatch
        XCTAssertTrue(
            rowText.waitForExistence(timeout: 10),
            "alert-row-Watchdog never appeared in detail view")

        // The headline text includes the alertmanager-name prefix because
        // `showAlertmanagerName` defaults to true.
        XCTAssertTrue(app.staticTexts["[Test AM] Watchdog"].exists)

        // The summary annotation is visible on the collapsed row.
        let summaryPredicate = NSPredicate(
            format: "identifier == 'alert-row-Watchdog' AND value CONTAINS 'alerting pipeline'")
        XCTAssertTrue(app.staticTexts.matching(summaryPredicate).firstMatch.exists)
    }

    @MainActor
    func testSidebarCountBadgeReflectsAlerts() throws {
        _ = try launchWithFakeServer(
            response: .alerts(json: FakeAlertmanagerPayloads.watchdog))

        // Children's accessibility labels are merged into the row Button's
        // label, so the count "1" appears as the trailing comma-separated
        // segment once the first poll completes.
        let row = seededSidebarRow()
        let label = waitForRowLabel(row) { $0.hasSuffix(", 1") }
        XCTAssertNotNil(label, "expected row label to end with ', 1', got \(row.label)")
    }

    // MARK: - Empty

    @MainActor
    func testEmptyResponseShowsZeroCount() throws {
        _ = try launchWithFakeServer(
            response: .alerts(json: FakeAlertmanagerPayloads.empty))

        let row = seededSidebarRow()
        let label = waitForRowLabel(row) { $0.hasSuffix(", 0") }
        XCTAssertNotNil(label, "expected row label to end with ', 0', got \(row.label)")

        row.click()
        XCTAssertTrue(app.staticTexts["No Alerts"].waitForExistence(timeout: 5))
    }

    // MARK: - Error

    @MainActor
    func testServerErrorShowsErrorBadge() throws {
        _ = try launchWithFakeServer(response: .status(500))

        // `Fetch error` is the accessibility label installed on the orange
        // warning badge in `SidebarAlertmanagerRowView`. It gets merged into
        // the enclosing row Button's label once the failed poll lands.
        let row = seededSidebarRow()
        let label = waitForRowLabel(row) { $0.contains("Fetch error") }
        XCTAssertNotNil(label, "expected row label to contain 'Fetch error', got \(row.label)")

        row.click()
        XCTAssertTrue(app.staticTexts["Failed to load alerts"].waitForExistence(timeout: 5))
    }
}
