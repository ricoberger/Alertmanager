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

    /// Filtered, deduplicated, sorted alerts displayed in the list.
    @State private var alerts: [GettableAlert] = []

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
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No Alerts")
                            .font(.headline)
                        Text("No alerts found for filter criteria")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                // Populated state. Each row needs its originating
                // alertmanager for deep-link construction; rows whose
                // source can no longer be resolved are skipped.
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredAlerts) { alert in
                            if let alertmanager = findAlertmanager(for: alert) {
                                AlertRowView(alert: alert, alertmanager: alertmanager)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(filter.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, maxWidth: 400)
                    .onSubmit {
                        searchMatchers = LabelMatcher.parse(query: searchQuery)
                    }
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
    private var filteredAlerts: [GettableAlert] {
        guard !searchMatchers.isEmpty else { return alerts }
        return alerts.filter { alert in
            searchMatchers.allSatisfy { $0.evaluate(against: alert.labels) }
        }
    }

    /// Recomputes `alerts` and `isLoading` from `AlertsManager`'s caches.
    ///
    /// Walks every alertmanager referenced by the filter **in sidebar order**,
    /// collects each backend's alerts, deduplicates by `fingerprint` (the same
    /// alert can be produced by multiple alertmanagers), applies the filter's
    /// predicates, and sorts newest-first. Iterating in sidebar order rather
    /// than `filter.selectedAlertmanagerIDs` order — which reflects the
    /// (effectively random) order checkboxes were ticked in the form — makes
    /// dedup precedence match what the user sees in the sidebar, and matches
    /// `AlertAggregator`'s contract.
    ///
    /// Notification checking is handled centrally by `NotificationService`,
    /// which subscribes to `.alertsDidUpdate` and checks all filters
    /// independently of which view is visible.
    private func updateAlerts() {
        let selected = Set(filter.selectedAlertmanagerIDs)
        var allAlerts: [GettableAlert] = []
        var seenFingerprints: Set<String> = []
        var anyLoading = false

        for alertmanager in alertmanagers where selected.contains(alertmanager.id) {
            let alerts = AlertsManager.shared.alertsByAlertmanager[alertmanager.id] ?? []

            for alert in alerts {
                if !seenFingerprints.contains(alert.fingerprint) {
                    seenFingerprints.insert(alert.fingerprint)
                    allAlerts.append(alert)
                }
            }

            if AlertsManager.shared.isLoadingByAlertmanager[alertmanager.id] ?? false {
                anyLoading = true
            }
        }

        let filteredAlerts = filter.apply(to: allAlerts).sorted { $0.startsAt > $1.startsAt }

        alerts = filteredAlerts
        isLoading = anyLoading
    }

    /// Forces an out-of-band refresh on every alertmanager referenced by
    /// the filter, bypassing the polling cadence.
    private func refreshAlerts() {
        for alertmanagerId in filter.selectedAlertmanagerIDs {
            if let alertmanager = alertmanagers.first(where: { $0.id == alertmanagerId }) {
                AlertsManager.shared.refresh(alertmanager: alertmanager)
            }
        }
    }

    /// Resolves which alertmanager produced `alert` so `AlertRowView` can
    /// construct correct silence/dashboard URLs.
    ///
    /// Searches each source alertmanager's cache for a matching alert id **in
    /// sidebar order**, so when the same fingerprint is present in multiple
    /// alertmanagers the row consistently pairs with the one that wins dedup
    /// in `updateAlerts()`. Falls back to the first known alertmanager if
    /// nothing matches (which can happen briefly when caches are still being
    /// populated).
    private func findAlertmanager(for alert: GettableAlert) -> Alertmanager? {
        let selected = Set(filter.selectedAlertmanagerIDs)
        for alertmanager in alertmanagers where selected.contains(alertmanager.id) {
            let alertmanagerAlerts =
                AlertsManager.shared.alertsByAlertmanager[alertmanager.id] ?? []
            if alertmanagerAlerts.contains(where: { $0.id == alert.id }) {
                return alertmanager
            }
        }
        return alertmanagers.first
    }

    /// Removes the filter from the model context. Polling is unaffected
    /// (timers are owned by alertmanagers, not filters).
    private func deleteFilter() {
        modelContext.delete(filter)
        NotificationCenter.default.post(name: .selectionDidDelete, object: nil)
    }
}
