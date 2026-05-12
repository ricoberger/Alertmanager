//
//  ContentView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Selected entry in the sidebar list. The detail column branches on this
/// value to render either an alertmanager or a filter view.
enum SidebarSelection: Hashable {
    case alertmanager(Alertmanager)
    case filter(Filter)
    /// A single alert opened from a notification tap. The associated
    /// `Alertmanager` is the one that produced the alert.
    case alertDetail(GettableAlert, Alertmanager)
}

/// Root view of the main window.
///
/// Hosts a `NavigationSplitView` with two sidebar sections (Filters and
/// Alertmanagers) and a detail column that renders the selected entry.
/// Also owns the global lifecycle hooks for polling, configuration
/// import/export, and the menu-command notifications posted from
/// `AlertmanagerApp`.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    /// All alertmanagers, kept ordered by their user-defined `sortOrder`.
    @Query(sort: \Alertmanager.sortOrder) private var alertmanagers: [Alertmanager]

    /// All filters, kept ordered by their user-defined `sortOrder`.
    @Query(sort: \Filter.sortOrder) private var filters: [Filter]

    /// Currently selected sidebar entry; drives the detail column.
    @State private var selectedItem: SidebarSelection?

    /// Presents the "Add Alertmanager" sheet. Triggered by the
    /// `.addAlertmanager` notification from the menu bar command.
    @State private var showingAddAlertmanager = false

    /// Presents the "Add Filter" sheet. Triggered by the `.addFilter`
    /// notification from the menu bar command.
    @State private var showingAddFilter = false

    /// Observed wrapper around `UserDefaults`. Used here to react to
    /// `refreshInterval` changes and restart all polling timers.
    @StateObject private var settings = SettingsManager.shared

    /// Controls the post-import confirmation alert.
    @State private var showingImportAlert = false

    /// Message body shown by the post-import alert.
    @State private var importMessage = ""

    /// Controls the reset-configuration confirmation dialog.
    @State private var showingResetConfirmation = false

    /// A pending alert-detail request that arrived before the alerts cache
    /// was populated (e.g. the app was launched by tapping a notification).
    /// Retried on every `.alertsDidUpdate` until it can be resolved.
    @State private var pendingAlertDetail: (fingerprint: String, alertmanagerID: UUID)?

    /// Set to `true` after a notification-tap resolution attempt fails on a
    /// cache refresh, meaning the alert was not found and has likely already
    /// been closed.
    @State private var notificationAlertNotFound = false

    /// Observes the singleton update-check service. The published
    /// `availableUpdate` drives the bottom-trailing "Update available"
    /// banner overlay.
    @StateObject private var updateCheck = UpdateCheckService.shared

    /// Per-session dismissal of the update banner. Reset on next launch so
    /// the banner reappears if the update is still applicable.
    @State private var updateBannerDismissed = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Sidebar: filters first, then alertmanagers. Both sections
                // support drag-to-reorder (which writes back `sortOrder`)
                // and swipe-to-delete.
                List(selection: $selectedItem) {
                    Section("Filters") {
                        ForEach(filters) { filter in
                            NavigationLink(value: SidebarSelection.filter(filter)) {
                                SidebarFilterRowView(filter: filter)
                            }
                        }
                        .onDelete(perform: deleteFilters)
                        .onMove(perform: moveFilters)
                    }

                    Section("Alertmanagers") {
                        ForEach(alertmanagers) { alertmanager in
                            NavigationLink(value: SidebarSelection.alertmanager(alertmanager)) {
                                SidebarAlertmanagerRowView(alertmanager: alertmanager)
                            }
                        }
                        .onDelete(perform: deleteAlertmanagers)
                        .onMove(perform: moveAlertmanagers)
                    }
                }
                .accessibilityIdentifier("sidebar-list")
                .frame(maxHeight: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 250)
        } detail: {
            // Detail column dispatches on the sidebar selection.
            if let selectedItem = selectedItem {
                switch selectedItem {
                case .alertmanager(let alertmanager):
                    AlertmanagerDetailView(alertmanager: alertmanager)
                case .filter(let filter):
                    FilterDetailView(filter: filter)
                case .alertDetail(let alert, let alertmanager):
                    ScrollView {
                        AlertRowView(alert: alert, alertmanager: alertmanager, isExpanded: true)
                            .padding()
                    }
                }
            } else if notificationAlertNotFound {
                ContentUnavailableView(
                    "Alert Not Found",
                    systemImage: "bell.slash",
                    description: Text(
                        "The alert could not be found. It may have already been resolved or expired."
                    )
                )
            }
        }
        .overlay(alignment: .bottom) {
            // Launch-time update notice. Only rendered when the version
            // probe has reported a newer release *and* the user hasn't
            // dismissed it in this session.
            if let update = updateCheck.availableUpdate, !updateBannerDismissed {
                UpdateAvailableBanner(update: update) {
                    updateBannerDismissed = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: updateCheck.availableUpdate)
        .animation(.easeInOut(duration: 0.2), value: updateBannerDismissed)
        .sheet(isPresented: $showingAddAlertmanager) {
            NavigationStack {
                AlertmanagerFormView()
            }
        }
        .sheet(isPresented: $showingAddFilter) {
            NavigationStack {
                FilterFormView()
            }
        }
        .onAppear {
            // Kick off polling for every persisted alertmanager. Repeated
            // calls are safe — `AlertsManager` replaces any existing timer
            // for the same alertmanager id.
            for alertmanager in alertmanagers {
                AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
            }
            // Pick up any notification tap that arrived before this view was
            // observing — including the cold-launch case where the user
            // launched the app by tapping a notification.
            if let pending = NotificationService.shared.consumePendingAlertDetail() {
                pendingAlertDetail = pending
            }
            // Resolve any pending notification tap that arrived before the
            // view had appeared and started polling.
            resolvePendingAlertDetail()
        }
        .onChange(of: settings.refreshInterval) { oldValue, newValue in
            // Refresh interval changed in Settings — restart every timer
            // so they pick up the new cadence immediately.
            for alertmanager in alertmanagers {
                AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
            }
        }
        // Bridge menu-command notifications (posted in AlertmanagerApp) to
        // local state changes. This indirection keeps the command builder
        // free of bindings into this view.
        .onReceive(NotificationCenter.default.publisher(for: .exportConfiguration)) { _ in
            exportConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .importConfiguration)) { _ in
            importConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetConfiguration)) { _ in
            showingResetConfirmation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .addAlertmanager)) { _ in
            showingAddAlertmanager = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFilter)) { _ in
            showingAddFilter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectionDidDelete)) { _ in
            selectedItem = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAlertDetail)) { notification in
            guard
                let fingerprint = notification.userInfo?["fingerprint"] as? String,
                let alertmanagerID = notification.userInfo?["alertmanagerID"] as? UUID
            else { return }
            NSApp.activate(ignoringOtherApps: true)
            // Clear any previous "not found" hint and store the new request
            // so it can be retried once the cache is ready.
            notificationAlertNotFound = false
            selectedItem = nil
            pendingAlertDetail = (fingerprint, alertmanagerID)
            resolvePendingAlertDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { _ in
            // Retry resolution on every cache refresh in case the alert
            // wasn't available yet when the notification tap arrived.
            resolvePendingAlertDetail()
        }
        .alert("Import Complete", isPresented: $showingImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .confirmationDialog(
            "Reset Configuration",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetConfiguration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will delete all alertmanagers and filters, and restore default settings. This action cannot be undone."
            )
        }
    }

    /// Attempts to resolve `pendingAlertDetail` against the current
    /// `alertmanagers` list and `AlertsManager` cache. When both the model
    /// and the cached alert are available, sets `selectedItem` and clears the
    /// pending request. Safe to call repeatedly — does nothing when there is
    /// no pending request or the data isn't ready yet.
    ///
    /// If the alertmanager is found but the alert is absent from the cache,
    /// the alert has likely already been resolved; `notificationAlertNotFound`
    /// is set so the detail column can show an appropriate hint.
    private func resolvePendingAlertDetail() {
        guard let pending = pendingAlertDetail else { return }
        guard let alertmanager = alertmanagers.first(where: { $0.id == pending.alertmanagerID })
        else { return }
        guard
            let alert = AlertsManager.shared.alertsByAlertmanager[pending.alertmanagerID]?
                .first(where: { $0.fingerprint == pending.fingerprint })
        else {
            // The alertmanager is known but the alert is missing from the
            // cache. Only surface the "not found" hint once the cache has
            // been populated at least once (i.e. the key exists), so we
            // don't give up before the first fetch completes.
            if AlertsManager.shared.alertsByAlertmanager[pending.alertmanagerID] != nil {
                pendingAlertDetail = nil
                selectedItem = nil
                notificationAlertNotFound = true
            }
            return
        }
        pendingAlertDetail = nil
        notificationAlertNotFound = false
        selectedItem = .alertDetail(alert, alertmanager)
    }

    /// Deletes the alertmanagers at the supplied offsets, first stopping
    /// their polling timers so they don't fire against a deleted model.
    private func deleteAlertmanagers(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let alertmanager = alertmanagers[index]
                if case .alertmanager(let selected) = selectedItem, selected == alertmanager {
                    selectedItem = nil
                }
                AlertsManager.shared.stopMonitoring(alertmanager: alertmanager)
                modelContext.delete(alertmanager)
            }
        }
    }

    /// Deletes filters at the supplied offsets.
    private func deleteFilters(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let filter = filters[index]
                if case .filter(let selected) = selectedItem, selected == filter {
                    selectedItem = nil
                }
                modelContext.delete(filter)
            }
        }
    }

    /// Reorders alertmanagers and rewrites every `sortOrder` to match the
    /// new positions, so the `@Query`-driven sort persists across launches.
    private func moveAlertmanagers(from source: IndexSet, to destination: Int) {
        var revisedAlertmanagers = alertmanagers.map { $0 }
        revisedAlertmanagers.move(fromOffsets: source, toOffset: destination)

        for (index, alertmanager) in revisedAlertmanagers.enumerated() {
            alertmanager.sortOrder = index
        }
    }

    /// Reorders filters and rewrites every `sortOrder` to match the new
    /// positions, so the `@Query`-driven sort persists across launches.
    private func moveFilters(from source: IndexSet, to destination: Int) {
        var revisedFilters = filters.map { $0 }
        revisedFilters.move(fromOffsets: source, toOffset: destination)

        for (index, filter) in revisedFilters.enumerated() {
            filter.sortOrder = index
        }
    }

    /// Serializes the current configuration to JSON and prompts the user
    /// for a save location via `NSSavePanel`. Silent on cancellation;
    /// failures are logged.
    private func exportConfiguration() {
        guard
            let data = ImportExportManager.exportData(
                alertmanagers: alertmanagers, filters: filters)
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "alertmanager.json"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                } catch {
                    print("Failed to save file: \(error)")
                }
            }
        }
    }

    /// Prompts the user for a JSON file via `NSOpenPanel`, imports its
    /// contents into the current `modelContext`, and starts polling for any
    /// newly added alertmanagers. Reports the outcome through the
    /// "Import Complete" alert.
    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let data = try Data(contentsOf: url)
                    let result = try ImportExportManager.importData(
                        from: data,
                        modelContext: modelContext,
                        existingAlertmanagers: alertmanagers
                    )

                    var message =
                        "Successfully imported \(result.alertmanagers) alertmanager(s) and \(result.filters) filter(s)."
                    if result.settingsRestored {
                        message += " Settings have been restored."
                    }
                    importMessage = message
                    showingImportAlert = true

                    // Begin polling for any alertmanagers added by the import.
                    // `startMonitoring` is idempotent for entries that were
                    // already being polled.
                    for alertmanager in alertmanagers {
                        AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
                    }
                } catch {
                    importMessage =
                        "Failed to import configuration: \(error.localizedDescription)"
                    showingImportAlert = true
                }
            }
        }
    }

    /// Deletes all alertmanagers and filters from the SwiftData store,
    /// stops all active polling timers, clears the sidebar selection, and
    /// restores every `SettingsManager` preference to its default value.
    private func resetConfiguration() {
        // Stop and remove all polling timers before deleting models.
        for alertmanager in alertmanagers {
            AlertsManager.shared.stopMonitoring(alertmanager: alertmanager)
        }

        // Delete every persisted alertmanager and filter.
        for alertmanager in alertmanagers {
            modelContext.delete(alertmanager)
        }
        for filter in filters {
            modelContext.delete(filter)
        }

        // Clear sidebar selection so the detail column doesn't reference
        // deleted objects.
        selectedItem = nil
        notificationAlertNotFound = false
        pendingAlertDetail = nil

        // Restore UserDefaults-backed settings to their defaults.
        let settings = SettingsManager.shared
        settings.refreshInterval = 60.0
        settings.menuBarEnabled = true
        settings.menuBarFilterID = nil
        settings.showAlertmanagerName = true
        settings.labelBadgeConfigs = []
        settings.aiConfig = .default
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Alertmanager.self, inMemory: true)
}
