//
//  AlertsManager.swift
//  Alertmanager
//

import Foundation
import SwiftUI

/// Cross-component event names broadcast on the default `NotificationCenter`.
extension Notification.Name {
    /// Posted by `AlertsManager` after every fetch completes (success or
    /// failure). `userInfo["alertmanagerId"]` carries the `UUID` of the
    /// affected alertmanager so observers can scope their reactions.
    static let alertsDidUpdate = Notification.Name("alertsDidUpdate")

    /// Posted by the "Export Configuration" menu command in
    /// `AlertmanagerApp`; observed by `ContentView`.
    static let exportConfiguration = Notification.Name("exportConfiguration")

    /// Posted by the "Import Configuration" menu command in
    /// `AlertmanagerApp`; observed by `ContentView`.
    static let importConfiguration = Notification.Name("importConfiguration")

    /// Posted by the "Add Alertmanager" menu command; observed by
    /// `ContentView` to present the form sheet.
    static let addAlertmanager = Notification.Name("addAlertmanager")

    /// Posted by the "Add Filter" menu command; observed by `ContentView`
    /// to present the form sheet.
    static let addFilter = Notification.Name("addFilter")

    /// Posted by a detail view after it deletes the currently displayed
    /// alertmanager or filter; observed by `ContentView` to clear the
    /// sidebar selection so the detail column no longer shows stale data.
    static let selectionDidDelete = Notification.Name("selectionDidDelete")

    /// Posted by `NotificationService` when the user taps the body of an
    /// alert notification (not one of its action buttons). The `userInfo`
    /// carries `"fingerprint"` (String) and `"alertmanagerID"` (UUID) so
    /// `AlertmanagerApp` can open the alert-detail window.
    static let openAlertDetail = Notification.Name("openAlertDetail")

    /// Posted by the "Reset Configuration" menu command in
    /// `AlertmanagerApp`; observed by `ContentView` to present a
    /// confirmation dialog before wiping all data and restoring defaults.
    static let resetConfiguration = Notification.Name("resetConfiguration")
}

/// Process-wide cache of fetched alerts plus the polling-timer registry.
///
/// Owns one repeating `Timer` per alertmanager keyed by `Alertmanager.id`.
/// Views observe this object via `@Observable` and additionally subscribe
/// to `.alertsDidUpdate` for explicit per-alertmanager change events.
///
/// Exposed as a singleton (`shared`) because polling state must outlive
/// any single view instance and be visible to both the main window and
/// the menu-bar popup.
@MainActor
@Observable
class AlertsManager {
    /// Process-wide singleton.
    static let shared = AlertsManager()

    /// Stateless HTTP client used for every fetch.
    private let service = AlertmanagerService()

    /// Active repeating timers, keyed by `Alertmanager.id`. Replaced on
    /// `startMonitoring`, removed on `stopMonitoring`.
    private var refreshTimers: [UUID: Timer] = [:]

    /// Tracks in-flight fetch tasks keyed by `Alertmanager.id` so that a
    /// second call to `fetchAlerts` while one is already running is a no-op.
    /// This prevents duplicate concurrent fetches when multiple views call
    /// `startMonitoring` for the same alertmanager on appear.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Per-alertmanager caches
    //
    // Each dictionary is keyed by `Alertmanager.id`. Kept as separate
    // dictionaries (rather than a struct value) so SwiftUI's `@Observable`
    // tracks fine-grained reads — a view that only inspects loading state
    // doesn't invalidate when alerts change.

    /// Most recent alerts for each alertmanager, sorted newest-first.
    var alertsByAlertmanager: [UUID: [GettableAlert]] = [:]

    /// Timestamp of the most recent successful fetch per alertmanager.
    var lastRefreshByAlertmanager: [UUID: Date] = [:]

    /// `true` once at least one fetch attempt — successful or failed —
    /// has completed for the alertmanager. Unlike
    /// `lastRefreshByAlertmanager`, this is also set when a fetch errors,
    /// so consumers (e.g. `NotificationService` baselining) can
    /// distinguish "never fetched yet" from "fetched but failing".
    var hasCompletedFetchByAlertmanager: [UUID: Bool] = [:]

    /// `true` while a fetch is in flight for the given alertmanager.
    var isLoadingByAlertmanager: [UUID: Bool] = [:]

    /// Localized description of the last failure per alertmanager, or
    /// `nil` when the most recent fetch succeeded.
    var errorByAlertmanager: [UUID: String?] = [:]

    private init() {}

    /// Begins (or restarts) periodic polling for `alertmanager`.
    ///
    /// Triggers an immediate one-shot fetch and installs a repeating
    /// timer at the cadence configured in `SettingsManager`. Calling this
    /// again for the same alertmanager replaces the previous timer, so
    /// the operation is idempotent and safe to call from multiple views'
    /// `.onAppear` handlers.
    func startMonitoring(alertmanager: Alertmanager) {
        // Kick off an immediate fetch so the UI doesn't have to wait one
        // full interval for its first data.
        Task {
            await fetchAlerts(for: alertmanager)
        }

        // Tear down any previous timer for this id before installing a
        // new one — avoids duplicate scheduled fetches. We deliberately
        // do NOT cancel in-flight tasks here: a fetch started by another
        // caller (e.g. `NotificationService` on cold launch) should be
        // allowed to complete so its `.alertsDidUpdate` notification fires
        // and observers see the populated cache.
        refreshTimers[alertmanager.id]?.invalidate()
        refreshTimers[alertmanager.id] = nil

        let interval = SettingsManager.shared.refreshInterval

        // `Alertmanager` is a SwiftData `@Model` and not `Sendable`. We
        // capture it via `nonisolated(unsafe)` to silence the diagnostic
        // — it's safe here because the timer fires on the main run loop
        // and we hop back to `@MainActor` immediately inside the closure.
        nonisolated(unsafe) let alertmanagerRef = alertmanager

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchAlerts(for: alertmanagerRef)
            }
        }
        refreshTimers[alertmanager.id] = timer
    }

    /// Stops polling for `alertmanager`, cancels any in-flight fetch, and
    /// clears all cached state for it. Safe to call when no timer is
    /// installed. Should be called before deleting the model so timer
    /// callbacks don't fire against a deleted entity and its alerts,
    /// errors, and loading flags don't linger in the caches forever.
    func stopMonitoring(alertmanager: Alertmanager) {
        refreshTimers[alertmanager.id]?.invalidate()
        refreshTimers[alertmanager.id] = nil
        inFlightTasks[alertmanager.id]?.cancel()
        inFlightTasks[alertmanager.id] = nil

        // Drop the per-alertmanager caches. The entries would otherwise
        // accumulate for every alertmanager ever deleted during the
        // app's lifetime. The cancelled fetch task bails out before
        // writing (see `fetchAlerts`), so it cannot resurrect them.
        alertsByAlertmanager[alertmanager.id] = nil
        lastRefreshByAlertmanager[alertmanager.id] = nil
        isLoadingByAlertmanager[alertmanager.id] = nil
        errorByAlertmanager[alertmanager.id] = nil
        hasCompletedFetchByAlertmanager[alertmanager.id] = nil
    }

    /// Triggers a one-shot out-of-band fetch without disturbing the
    /// existing polling cadence. Used by toolbar refresh buttons and
    /// retry actions.
    func refresh(alertmanager: Alertmanager) {
        Task {
            await fetchAlerts(for: alertmanager)
        }
    }

    /// Performs a single fetch and updates the per-alertmanager caches.
    ///
    /// On success, alerts are sorted newest-first and `lastRefresh` is
    /// stamped. On failure, `errorByAlertmanager` records the localized
    /// message and the previous alert list is left in place (so a
    /// transient network blip doesn't blank the UI).
    ///
    /// Concurrent calls for the same alertmanager are deduplicated: if a
    /// fetch is already in flight the second call returns immediately,
    /// letting the in-flight task post its own `.alertsDidUpdate`
    /// notification when it finishes.
    ///
    /// A `.alertsDidUpdate` notification is posted at the end regardless
    /// of outcome, scoped to this alertmanager's id.
    func fetchAlerts(for alertmanager: Alertmanager) async {
        // Deduplicate: if a fetch is already running for this alertmanager,
        // don't start a second concurrent one.
        if inFlightTasks[alertmanager.id] != nil {
            return
        }

        let task = Task {
            isLoadingByAlertmanager[alertmanager.id] = true
            errorByAlertmanager[alertmanager.id] = nil

            do {
                let fetchedAlerts = try await service.fetchAlerts(for: alertmanager)
                // A cancelled fetch means `stopMonitoring` ran (the entity
                // is being deleted) and already cleared the caches — bail
                // out before any write resurrects entries for it.
                guard !Task.isCancelled else { return }
                alertsByAlertmanager[alertmanager.id] = fetchedAlerts.sorted {
                    $0.startsAt > $1.startsAt
                }
                lastRefreshByAlertmanager[alertmanager.id] = Date()
            } catch {
                // Same cancellation guard as above: URLSession surfaces a
                // cancelled task as an error, which would otherwise be
                // recorded in `errorByAlertmanager`.
                guard !Task.isCancelled else { return }
                errorByAlertmanager[alertmanager.id] = error.localizedDescription
                print("Error fetching alerts for alertmanager \(alertmanager.name): \(error)")
            }

            isLoadingByAlertmanager[alertmanager.id] = false
            hasCompletedFetchByAlertmanager[alertmanager.id] = true
            inFlightTasks[alertmanager.id] = nil

            // Broadcast the change. Listeners can scope by reading
            // `userInfo["alertmanagerId"]`.
            NotificationCenter.default.post(
                name: .alertsDidUpdate,
                object: nil,
                userInfo: ["alertmanagerId": alertmanager.id]
            )
        }

        inFlightTasks[alertmanager.id] = task
        await task.value
    }

    /// Returns the cached alerts for `alertmanager`, or an empty array if
    /// none have been fetched yet.
    func getAlerts(for alertmanager: Alertmanager) -> [GettableAlert] {
        return alertsByAlertmanager[alertmanager.id] ?? []
    }

    /// Returns whether a fetch is currently in flight for `alertmanager`.
    func isLoading(for alertmanager: Alertmanager) -> Bool {
        return isLoadingByAlertmanager[alertmanager.id] ?? false
    }

    /// Returns the last error message for `alertmanager`, or `nil` if the
    /// most recent fetch succeeded (or none has happened yet).
    func getError(for alertmanager: Alertmanager) -> String? {
        return errorByAlertmanager[alertmanager.id] ?? nil
    }
}
