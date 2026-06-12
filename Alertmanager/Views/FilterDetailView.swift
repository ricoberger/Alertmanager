//
//  FilterDetailView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Detail column shown when a filter is selected in the sidebar.
///
/// Aggregates alerts from every alertmanager referenced by the filter,
/// deduplicates them by fingerprint, applies the filter's predicates, and
/// sorts the result newest-first. Notification opt-in is honored by
/// forwarding the matched set to `NotificationService` on every update.
struct FilterDetailView: View {
    @Environment(\.modelContext) private var modelContext

    /// The filter being displayed. `@Bindable` so the edit sheet can
    /// mutate it directly.
    @Bindable var filter: Filter

    /// Presents the edit sheet (`FilterFormView` in edit mode).
    @State private var showingEditSheet = false

    /// Presents the destructive delete confirmation alert.
    @State private var showingDeleteAlert = false

    /// Filtered, deduplicated, sorted alerts displayed in the list, each
    /// paired with the alertmanager that won dedup (needed by
    /// `AlertRowView` for deep-link construction).
    @State private var alerts: [(alert: GettableAlert, alertmanager: Alertmanager)] = []

    /// `true` while at least one source alertmanager is performing an
    /// initial fetch.
    @State private var isLoading: Bool = false

    /// Bumped on edit-sheet dismissal to force `updateAlerts()` to re-run
    /// against the (potentially mutated) filter predicates.
    @State private var filterVersion: Int = 0

    /// Raw text typed into the toolbar search field.
    /// Parsed on change into `searchMatchers`.
    @State private var searchQuery: String = ""

    /// Parsed label matchers derived from `searchQuery`.
    @State private var searchMatchers: [LabelMatcher] = []

    /// All alertmanagers in sidebar order, used to resolve filter
    /// `selectedAlertmanagerIDs` back to entities for refresh and deep-link
    /// construction. The sort order determines dedup precedence when the same
    /// alert fingerprint appears in more than one alertmanager (matches the
    /// behaviour of `AlertAggregator`, `SidebarFilterRowView`, and the
    /// menu-bar popup).
    @Query(sort: \Alertmanager.sortOrder) private var alertmanagers: [Alertmanager]

    var body: some View {
        Group {
            if isLoading && alerts.isEmpty {
                // Initial fetch across all source alertmanagers.
                VStack {
                    Spacer()
                    ProgressView("Loading alerts...")
                    Spacer()
                }
            } else if alerts.isEmpty {
                // Healthy empty state: nothing currently matches the filter.
                VStack {
                    Spacer()
                    ContentPlaceholderView(
                        systemImage: "checkmark.circle",
                        iconColor: .green,
                        title: "No Alerts",
                        message: "No alerts found for filter criteria"
                    )
                    Spacer()
                }
            } else {
                // Populated state. Each row carries its dedup-winning
                // alertmanager for deep-link construction.
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredAlerts, id: \.alert.id) { item in
                            AlertRowView(alert: item.alert, alertmanager: item.alertmanager)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(filter.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                AlertSearchField(query: $searchQuery, matchers: $searchMatchers)
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    refreshAlerts()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            ToolbarItem(placement: .automatic) {
                Button(action: {
                    showingEditSheet = true
                }) {
                    Label("Edit", systemImage: "pencil")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button(
                    role: .destructive,
                    action: {
                        showingDeleteAlert = true
                    }
                ) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(
            isPresented: $showingEditSheet,
            onDismiss: {
                // Bump `filterVersion` so `.onChange` re-runs `updateAlerts()`
                // — predicate mutations on `filter` aren't observable directly.
                filterVersion += 1
            }
        ) {
            NavigationStack {
                FilterFormView(filter: filter)
            }
        }
        .alert("Delete", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteFilter()
            }
        } message: {
            Text("Are you sure you want to delete '\(filter.name)'? This action cannot be undone.")
        }
        .onAppear {
            updateAlerts()
        }
        // Re-aggregate whenever any alertmanager's cache changes; we don't
        // filter by id here because the filter may span several backends.
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { _ in
            updateAlerts()
        }
        .onChange(of: filterVersion) { oldValue, newValue in
            updateAlerts()
        }
        .onChange(of: filter.id) { oldValue, newValue in
            // The detail view is reused when the sidebar selection changes
            // to a different filter — re-aggregate from scratch.
            searchQuery = ""
            searchMatchers = []
            updateAlerts()
        }
    }

    /// Alerts after applying the user's live search matchers on top of
    /// the filter's own predicates.
    ///
    /// When `searchMatchers` is empty (no or unparseable query) the
    /// filter-matched `alerts` list is returned unchanged.
    private var filteredAlerts: [(alert: GettableAlert, alertmanager: Alertmanager)] {
        guard !searchMatchers.isEmpty else { return alerts }
        return alerts.filter { item in
            searchMatchers.allSatisfy { $0.evaluate(against: item.alert.labels) }
        }
    }

    /// Recomputes `alerts` and `isLoading` from `AlertsManager`'s caches.
    ///
    /// Aggregation (sidebar-order visitation, dedup by fingerprint, filter
    /// predicates, alert-to-alertmanager pairing, newest-first sort) is
    /// delegated to `AlertAggregator.alertsWithSources`, the same helper
    /// the menu bar popup uses — so both surfaces always agree.
    ///
    /// Notification checking is handled centrally by `NotificationService`,
    /// which subscribes to `.alertsDidUpdate` and checks all filters
    /// independently of which view is visible.
    private func updateAlerts() {
        alerts = AlertAggregator.alertsWithSources(
            for: filter,
            from: AlertsManager.shared.alertsByAlertmanager,
            orderedAlertmanagers: alertmanagers
        )
        isLoading = alertmanagers.contains {
            filter.includesAlertmanager(withID: $0.id)
                && (AlertsManager.shared.isLoadingByAlertmanager[$0.id] ?? false)
        }
    }

    /// Forces an out-of-band refresh on every alertmanager referenced by
    /// the filter, bypassing the polling cadence. An empty selection
    /// refreshes all alertmanagers.
    private func refreshAlerts() {
        for alertmanager in alertmanagers
        where filter.includesAlertmanager(withID: alertmanager.id) {
            AlertsManager.shared.refresh(alertmanager: alertmanager)
        }
    }

    /// Removes the filter from the model context. Polling is unaffected
    /// (timers are owned by alertmanagers, not filters).
    private func deleteFilter() {
        modelContext.delete(filter)
        NotificationCenter.default.post(name: .selectionDidDelete, object: nil)
    }
}
