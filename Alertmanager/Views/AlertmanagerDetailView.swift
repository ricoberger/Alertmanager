//
//  AlertmanagerDetailView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Detail column shown when an alertmanager is selected in the sidebar.
///
/// Renders the cached alerts for `alertmanager` in one of four states —
/// initial loading, error, empty, or populated — and exposes toolbar
/// actions for refresh, edit, and delete. The view does not call the
/// network directly: it observes `AlertsManager.shared` and the
/// `.alertsDidUpdate` notification to mirror its cache.
struct AlertmanagerDetailView: View {
    @Environment(\.modelContext) private var modelContext

    /// The alertmanager being displayed. `@Bindable` so the edit sheet can
    /// mutate it through bindings.
    @Bindable var alertmanager: Alertmanager

    /// Presents the edit sheet (`AlertmanagerFormView` in edit mode).
    @State private var showingEditSheet = false

    /// Presents the destructive delete confirmation alert.
    @State private var showingDeleteAlert = false

    /// Locally mirrored copy of `AlertsManager`'s cached alerts for this
    /// alertmanager. Refreshed from `updateFromManager()`.
    @State private var alerts: [GettableAlert] = []

    /// Mirrors the manager's per-alertmanager loading flag.
    @State private var isLoading: Bool = false

    /// Mirrors the manager's last error string, if any.
    @State private var error: String?

    /// Raw text typed into the toolbar search field.
    /// Parsed on change into `searchMatchers`.
    @State private var searchQuery: String = ""

    /// Parsed label matchers derived from `searchQuery`.
    @State private var searchMatchers: [LabelMatcher] = []

    var body: some View {
        Group {
            if isLoading && alerts.isEmpty {
                // Initial fetch: show a spinner. Subsequent refreshes keep
                // the previous list visible so the UI doesn't flash.
                VStack {
                    Spacer()
                    ProgressView("Loading alerts...")
                    Spacer()
                }
            } else if let error = error {
                // Error state: show the message and a retry button that
                // forces a one-shot refresh outside the polling cadence.
                // Shown even when stale alerts are cached so the failure
                // is never silently hidden behind old data.
                VStack {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Failed to load alerts")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            AlertsManager.shared.refresh(alertmanager: alertmanager)
                        }
                    }
                    Spacer()
                }
            } else if alerts.isEmpty {
                // Healthy empty state: backend reachable, no active alerts.
                VStack {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No Alerts")
                            .font(.headline)
                        Text("No alerts found for this Alertmanager")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                // Populated state: scrollable list of alert rows.
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredAlerts) { alert in
                            AlertRowView(alert: alert, alertmanager: alertmanager)
                        }
                    }
                    .padding()
                }
            }
        }
        // Prefer the configured name, fall back to the URL when unnamed.
        .navigationTitle(alertmanager.name.isEmpty ? alertmanager.url : alertmanager.name)
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
                    AlertsManager.shared.refresh(alertmanager: alertmanager)
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                // Disable while a fetch is in flight to avoid stacked requests.
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
        .sheet(isPresented: $showingEditSheet) {
            NavigationStack {
                AlertmanagerFormView(alertmanager: alertmanager)
            }
        }
        .alert("Delete", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAlertmanager()
            }
        } message: {
            Text(
                "Are you sure you want to delete '\(alertmanager.name.isEmpty ? alertmanager.url : alertmanager.name)'? This action cannot be undone."
            )
        }
        .onAppear {
            // Ensure polling is running (idempotent) and seed the local
            // mirrors from whatever is already cached.
            AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
            updateFromManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { notification in
            // The manager broadcasts updates for every alertmanager — only
            // refresh local state when the notification matches ours.
            if let alertmanagerId = notification.userInfo?["alertmanagerId"] as? UUID,
                alertmanagerId == alertmanager.id
            {
                updateFromManager()
            }
        }
        .onChange(of: alertmanager.id) { oldValue, newValue in
            // The detail view is reused when the sidebar selection changes
            // to a different alertmanager — re-seed from the cache.
            searchQuery = ""
            searchMatchers = []
            updateFromManager()
        }
    }

    /// Alerts after applying the user's live search matchers.
    ///
    /// When `searchMatchers` is empty (no or unparseable query) the full
    /// `alerts` list is returned unchanged.
    private var filteredAlerts: [GettableAlert] {
        guard !searchMatchers.isEmpty else { return alerts }
        return alerts.filter { alert in
            searchMatchers.allSatisfy { $0.evaluate(against: alert.labels) }
        }
    }

    /// Pulls the latest cached state for `alertmanager` from
    /// `AlertsManager.shared` into the local `@State` mirrors.
    private func updateFromManager() {
        alerts = AlertsManager.shared.getAlerts(for: alertmanager)
        isLoading = AlertsManager.shared.isLoading(for: alertmanager)
        error = AlertsManager.shared.getError(for: alertmanager)
    }

    /// Stops polling and removes the entity from the model context.
    /// Stopping first avoids timer callbacks firing against a deleted model.
    private func deleteAlertmanager() {
        AlertsManager.shared.stopMonitoring(alertmanager: alertmanager)
        modelContext.delete(alertmanager)
        NotificationCenter.default.post(name: .selectionDidDelete, object: nil)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Alertmanager.self, configurations: config)

    let alertmanager = Alertmanager(
        name: "Test Alertmanager",
        url: "https://alertmanager.example.com",
        isGrafana: true,
        grafanaAlertmanager: "grafana",
        authType: .basicAuth(username: "admin", password: "secret")
    )
    container.mainContext.insert(alertmanager)

    return AlertmanagerDetailView(alertmanager: alertmanager)
        .modelContainer(container)
}
