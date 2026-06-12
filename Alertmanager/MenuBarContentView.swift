//
//  MenuBarContentView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Content of the `MenuBarExtra` popup window.
///
/// Displays alerts from the user-selected "menu bar filter" (configured in
/// Settings via `@AppStorage("menuBarFilterID")`). Reads the same SwiftData
/// store and `AlertsManager` cache as the main window, so polling already
/// performed by `ContentView` is reused without additional network traffic.
struct MenuBarContentView: View {
    @Environment(\.modelContext) private var modelContext

    /// All alertmanagers in sidebar order — filtered down to those referenced
    /// by the selected filter when computing `filteredAlerts`. The sort order
    /// determines dedup precedence when the same alert fingerprint appears in
    /// more than one alertmanager.
    @Query(sort: \Alertmanager.sortOrder) private var alertmanagers: [Alertmanager]

    /// All filters — used to resolve the menu-bar filter by its stored UUID.
    @Query private var filters: [Filter]

    /// Shared in-memory alert cache populated by polling timers.
    @State private var alertsManager = AlertsManager.shared

    /// UUID string of the filter selected in Settings for menu-bar display.
    /// `nil` means the user has not picked a filter yet.
    @AppStorage("menuBarFilterID") private var menuBarFilterID: String?

    /// Resolves `menuBarFilterID` against the current set of filters.
    /// Returns `nil` if no ID is stored or the referenced filter no longer
    /// exists (e.g. it was deleted from the main window).
    private var selectedFilter: Filter? {
        guard let id = menuBarFilterID, let uuid = UUID(uuidString: id) else {
            return nil
        }
        return filters.first { $0.id == uuid }
    }

    /// Alerts matching the selected filter, paired with the alertmanager
    /// they originated from (needed for deep-link construction in
    /// `AlertRowView`).
    ///
    /// Aggregation (sidebar-order visitation, dedup by fingerprint, filter
    /// predicates, newest-first sort) is delegated to
    /// `AlertAggregator.alertsWithSources`, the same helper the filter
    /// detail view uses — so the popup and the main window always agree.
    private var filteredAlerts: [(alert: GettableAlert, alertmanager: Alertmanager)] {
        guard let filter = selectedFilter else { return [] }
        return AlertAggregator.alertsWithSources(
            for: filter,
            from: alertsManager.alertsByAlertmanager,
            orderedAlertmanagers: alertmanagers
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if menuBarFilterID == nil {
                // Empty state: user hasn't configured a filter for the menu bar.
                ContentPlaceholderView(
                    systemImage: "line.3.horizontal.decrease.circle",
                    iconColor: .orange,
                    title: "No Filter Selected",
                    message: "Select a filter in the settings to show alerts here"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("menubar-no-filter-state")
            } else if filteredAlerts.isEmpty {
                // Empty state: filter is configured but currently matches
                // nothing.
                ContentPlaceholderView(
                    systemImage: "checkmark.circle",
                    iconColor: .green,
                    title: "No Alerts",
                    message: "No alerts found for filter criteria"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("menubar-empty-state")
            } else {
                // Populated state: scrollable list of alert rows.
                // `isMenuBar: true` tells `AlertRowView` to render its compact
                // menu-bar layout.
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredAlerts, id: \.alert.id) { item in
                            AlertRowView(
                                alert: item.alert,
                                alertmanager: item.alertmanager,
                                isMenuBar: true,
                            )
                        }
                    }
                    .padding(8)
                }
                .accessibilityIdentifier("menubar-alerts-list")
            }
        }
        // Fixed popup size; required because `MenuBarExtra` with `.window`
        // style does not auto-size its content.
        .frame(width: 500, height: 600)
    }
}
