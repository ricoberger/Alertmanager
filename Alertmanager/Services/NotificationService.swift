//
//  NotificationService.swift
//  Alertmanager
//

import AppKit
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// `userInfo` keys used to ferry deep-link URLs through the notification
/// payload to the action handler in `NotificationService`.
enum NotificationUserInfoKey {
    static let sourceURL = "sourceURL"
    static let silenceURL = "silenceURL"
    static let runbookURL = "runbookURL"
    static let dashboardURL = "dashboardURL"
    static let panelURL = "panelURL"
    /// Fingerprint of the alert — used to look it up in `AlertsManager` cache.
    static let fingerprint = "fingerprint"
    /// UUID string of the alertmanager that produced the alert.
    static let alertmanagerID = "alertmanagerID"
}

/// `UNNotificationAction` identifiers used by `NotificationService`.
enum NotificationActionIdentifier {
    static let openSource = "OPEN_SOURCE"
    static let openSilence = "OPEN_SILENCE"
    static let openRunbook = "OPEN_RUNBOOK"
    static let openDashboard = "OPEN_DASHBOARD"
    static let openPanel = "OPEN_PANEL"
}

/// Coordinates local user notifications for newly-seen alerts on a
/// per-filter basis.
///
/// Lifecycle:
/// 1. Singleton is constructed once from `AlertmanagerApp.onAppear`,
///    which triggers the system authorization prompt and registers
///    notification categories with deep-link actions.
/// 2. On construction, `NotificationService` subscribes to
///    `.alertsDidUpdate` and calls `checkForNewAlerts` for **all**
///    filters whenever any alertmanager cache is refreshed — regardless
///    of which view is open or whether the main window is visible.
/// 3. The first call for a given filter id is treated as a baseline —
///    no notifications are sent — so the user isn't blasted with a
///    notification per existing alert at app launch.
/// 4. Subsequent calls diff the current alert fingerprints against the
///    previously seen set and notify only on additions.
///
/// State is in-memory only; restarting the app re-baselines every
/// filter, which is the desired behavior.
@MainActor
class NotificationService: NSObject {
    /// Process-wide singleton. Callers must invoke `configure(with:)`
    /// before the first `.alertsDidUpdate` fires.
    static let shared = NotificationService()

    /// SwiftData context used to fetch all `Filter` and `Alertmanager`
    /// entities when an `.alertsDidUpdate` notification arrives.
    /// Set once during app startup via `configure(with:)`.
    fileprivate var modelContext: ModelContext?

    /// A notification tap that arrived before any view was ready to handle
    /// it (e.g. the app was cold-launched by tapping a notification, or the
    /// main window was closed at the time). `ContentView` consumes this on
    /// `onAppear` via `consumePendingAlertDetail()` and shows the alert in
    /// the detail column.
    private(set) var pendingAlertDetail: (fingerprint: String, alertmanagerID: UUID)?

    /// Returns and clears any pending alert-detail request stored by a
    /// notification tap that fired before a view could observe it.
    func consumePendingAlertDetail() -> (fingerprint: String, alertmanagerID: UUID)? {
        defer { pendingAlertDetail = nil }
        return pendingAlertDetail
    }

    /// Per-filter set of alert fingerprints already observed. Used to
    /// compute the "new since last fetch" delta.
    private var seenAlertsByFilter: [UUID: Set<String>] = [:]

    /// Filters whose baseline has been recorded. Until a filter id
    /// appears here, `checkForNewAlerts` treats the call as the first
    /// fetch and suppresses notifications.
    private var initializedFilters: Set<UUID> = []

    private override init() {
        super.init()
        requestNotificationPermissions()
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self

        // Subscribe to every alertmanager cache refresh so we can check
        // all filters, not just the one selected in the main window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(alertsDidUpdate(_:)),
            name: .alertsDidUpdate,
            object: nil
        )
    }

    /// Wires up the SwiftData context that `NotificationService` uses to
    /// query all filters and alertmanagers on each refresh.
    ///
    /// Call this once from `AlertmanagerApp` after the shared
    /// `ModelContainer` is available.
    func configure(with container: ModelContainer) {
        modelContext = ModelContext(container)
    }

    /// Called on every `.alertsDidUpdate` notification — i.e. after every
    /// alertmanager fetch, whether the main window is open or not.
    ///
    /// Fetches all `Filter` and `Alertmanager` entities from SwiftData and
    /// calls `checkForNewAlerts` for each filter that has notifications
    /// enabled, using `AlertsManager`'s in-memory caches as the alert source.
    @objc private func alertsDidUpdate(_ notification: Foundation.Notification) {
        guard let modelContext else { return }

        do {
            let filters = try modelContext.fetch(FetchDescriptor<Filter>())
            let alertmanagers = try modelContext.fetch(
                FetchDescriptor<Alertmanager>(sortBy: [SortDescriptor(\.sortOrder)])
            )
            let orderedIDs = alertmanagers.map(\.id)

            for filter in filters {
                let allAlerts = AlertAggregator.alerts(
                    for: filter,
                    from: AlertsManager.shared.alertsByAlertmanager,
                    orderedAlertmanagerIDs: orderedIDs
                ).sorted { $0.startsAt > $1.startsAt }
                checkForNewAlerts(filter: filter, alerts: allAlerts, alertmanagers: alertmanagers)
            }
        } catch {
            print("NotificationService: failed to fetch filters/alertmanagers: \(error)")
        }
    }

    /// Prompts the user for permission to deliver alerts, sounds, and
    /// badges. The prompt is only shown once per install; subsequent
    /// invocations resolve immediately with the stored decision.
    func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, error in
            if granted {
                print("Notification permissions granted")
            } else if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            } else {
                print("Notification permissions denied")
            }
        }
    }

    /// Pre-registers every possible combination of the five deep-link
    /// actions (2⁵ = 32 categories) so each notification can be assigned
    /// the exact category that matches the links present on that alert.
    ///
    /// Category identifiers follow the pattern
    /// `"ALERT_<bitmask>"` where the bitmask bits are, from LSB:
    /// source(0), silence(1), runbook(2), dashboard(3), panel(4).
    private func registerNotificationCategories() {
        let allActions: [(bit: Int, action: UNNotificationAction)] = [
            (
                0,
                UNNotificationAction(
                    identifier: "OPEN_SOURCE", title: "Source", options: .foreground)
            ),
            (
                1,
                UNNotificationAction(
                    identifier: "OPEN_SILENCE", title: "Silence", options: .foreground)
            ),
            (
                2,
                UNNotificationAction(
                    identifier: "OPEN_RUNBOOK", title: "Runbook", options: .foreground)
            ),
            (
                3,
                UNNotificationAction(
                    identifier: "OPEN_DASHBOARD", title: "Dashboard", options: .foreground)
            ),
            (
                4,
                UNNotificationAction(identifier: "OPEN_PANEL", title: "Panel", options: .foreground)
            ),
        ]

        var categories: Set<UNNotificationCategory> = []
        // Start at 1 — bitmask 0 means no actions, no category needed.
        for mask in 1..<32 {
            let actions =
                allActions
                .filter { mask & (1 << $0.bit) != 0 }
                .map { $0.action }
            let category = UNNotificationCategory(
                identifier: "ALERT_\(mask)",
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
            categories.insert(category)
        }

        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    /// Returns the `categoryIdentifier` string for the set of URLs that
    /// are present for a given alert notification.
    ///
    /// Bit positions match `registerNotificationCategories`:
    /// - bit 0 → source
    /// - bit 1 → silence
    /// - bit 2 → runbook
    /// - bit 3 → dashboard
    /// - bit 4 → panel
    func categoryIdentifier(for userInfo: [String: String]) -> String {
        var mask = 0
        if userInfo[NotificationUserInfoKey.sourceURL] != nil { mask |= 1 << 0 }
        if userInfo[NotificationUserInfoKey.silenceURL] != nil { mask |= 1 << 1 }
        if userInfo[NotificationUserInfoKey.runbookURL] != nil { mask |= 1 << 2 }
        if userInfo[NotificationUserInfoKey.dashboardURL] != nil { mask |= 1 << 3 }
        if userInfo[NotificationUserInfoKey.panelURL] != nil { mask |= 1 << 4 }
        return "ALERT_\(mask)"
    }

    /// Diffs the current alert set against the previously seen set for
    /// `filter` and notifies on additions.
    ///
    /// - First call for a given filter id where all covered alertmanagers
    ///   have completed at least one fetch attempt (successful or failed):
    ///   records the baseline silently. If some alertmanagers haven't
    ///   fetched yet the call is skipped entirely so partial data doesn't
    ///   contaminate the baseline and cause spurious notifications once
    ///   the remaining fetches land. An empty
    ///   `filter.selectedAlertmanagerIDs` covers all alertmanagers, and
    ///   IDs that no longer resolve to a known alertmanager (deleted
    ///   entries) are ignored — both would otherwise gate the baseline on
    ///   alertmanagers that can never report a fetch.
    /// - Subsequent calls: any fingerprint not in the previous set is
    ///   considered new, and a notification is dispatched per new alert.
    /// - The seen-set is then replaced with `currentFingerprints` (alerts
    ///   that resolved are forgotten, so they'll re-notify if they
    ///   re-fire).
    ///
    /// Does nothing when `filter.notificationsEnabled` is `false`.
    ///
    /// - Parameters:
    ///   - filter: The filter whose alert set is being evaluated.
    ///   - alerts: The current matched alert list (already filtered and sorted).
    ///   - alertmanagers: All known alertmanagers, used to resolve the
    ///     alertmanager that produced each alert so that deep-link URLs
    ///     (silence, dashboard, panel) can be constructed correctly.
    func checkForNewAlerts(filter: Filter, alerts: [GettableAlert], alertmanagers: [Alertmanager]) {
        guard filter.notificationsEnabled else { return }

        // Wait until every alertmanager covered by this filter has
        // completed at least one fetch attempt. This prevents a race where
        // the first alertmanager to finish sets a partial baseline; when
        // the second finishes its alerts would all appear "new". Gating on
        // completed *attempts* (rather than successes) keeps one
        // permanently failing alertmanager from blocking notifications for
        // the healthy ones forever. The covered set is resolved against
        // the known alertmanagers so stale IDs left behind by deleted
        // entries — which can never fetch again — don't stall the
        // baseline either; an empty selection covers all alertmanagers.
        let knownIDs = alertmanagers.map(\.id)
        let coveredIDs =
            filter.selectedAlertmanagerIDs.isEmpty
            ? knownIDs
            : filter.selectedAlertmanagerIDs.filter { knownIDs.contains($0) }
        let allFetched = coveredIDs.allSatisfy {
            AlertsManager.shared.hasCompletedFetchByAlertmanager[$0] == true
        }
        guard allFetched else { return }

        let currentFingerprints = Set(alerts.map { $0.fingerprint })

        let isFirstFetch = !initializedFilters.contains(filter.id)

        if isFirstFetch {
            // Baseline pass: record the current state without notifying
            // so the user isn't spammed at app launch with one
            // notification per pre-existing alert.
            seenAlertsByFilter[filter.id] = currentFingerprints
            initializedFilters.insert(filter.id)
            print(
                "Initialized filter '\(filter.name)' with \(currentFingerprints.count) alert(s) - no notifications sent"
            )
        } else {
            let previousFingerprints = seenAlertsByFilter[filter.id] ?? Set()

            // Set difference: fingerprints present now but not before.
            let newFingerprints = currentFingerprints.subtracting(previousFingerprints)

            if !newFingerprints.isEmpty {
                let newAlerts = alerts.filter { newFingerprints.contains($0.fingerprint) }
                Task {
                    await sendNotifications(
                        for: newAlerts, filter: filter, alertmanagers: alertmanagers)
                }
            }

            // Replace (not union) so that resolved alerts can re-notify
            // if they fire again later.
            seenAlertsByFilter[filter.id] = currentFingerprints
        }
    }

    /// Posts one local user notification per alert.
    ///
    /// Notification content:
    /// - **title**: alert name.
    /// - **subtitle**: severity (when present in labels).
    /// - **body**: the alert subtitle (typically `summary`/`description`).
    /// - **actions**: Source, Silence, Runbook, Dashboard, Panel — only
    ///   those whose URLs can be resolved for the specific alert are
    ///   stored in `userInfo` and therefore actionable.
    ///
    /// The request identifier is `"alert-<fingerprint>"`, which causes
    /// the notification center to coalesce duplicates if the same alert
    /// somehow re-arrives.
    private func sendNotifications(
        for alerts: [GettableAlert], filter: Filter, alertmanagers: [Alertmanager]
    ) async {
        let center = UNUserNotificationCenter.current()
        let service = AlertmanagerService()

        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.alertName

            if let severity = alert.labels["severity"] {
                content.subtitle = "Severity: \(severity)"
            }

            if let subtitle = alert.subtitle {
                content.body = subtitle
            }

            content.sound = .default

            // Resolve the alertmanager that produced this alert so we can
            // build backend-specific URLs (silence, dashboard, panel).
            let alertmanager = resolveAlertmanager(for: alert, in: alertmanagers)

            var userInfo: [String: String] = [:]

            // Always store fingerprint and alertmanager ID so the default
            // notification tap can open the alert-detail window.
            userInfo[NotificationUserInfoKey.fingerprint] = alert.fingerprint
            if let alertmanager {
                userInfo[NotificationUserInfoKey.alertmanagerID] = alertmanager.id.uuidString
            }

            // Source — present only when the alert carries a generatorURL.
            if let generatorURL = alert.generatorURL,
                let sanitized = sanitizeURL(generatorURL)
            {
                userInfo[NotificationUserInfoKey.sourceURL] = sanitized
            }

            // Silence — always constructible when the alertmanager is known.
            // For Grafana backends, resolve the datasource name from its UID
            // first (unless the UID is already the built-in "grafana" value).
            if let alertmanager {
                let configuredUID =
                    alertmanager.grafanaAlertmanager.isEmpty
                    ? nil : alertmanager.grafanaAlertmanager
                let resolvedName: String?
                if alertmanager.isGrafana, let uid = configuredUID, uid != "grafana" {
                    resolvedName = await service.fetchDatasourceName(for: uid, in: alertmanager)
                } else {
                    resolvedName = nil
                }

                if let silenceURL = buildSilenceURL(
                    for: alert,
                    alertmanager: alertmanager,
                    resolvedDatasourceName: resolvedName
                ) {
                    userInfo[NotificationUserInfoKey.silenceURL] = silenceURL
                }
            }

            // Runbook — present only when the annotation exists.
            if let runbookURL = alert.runbookURL,
                let sanitized = sanitizeURL(runbookURL)
            {
                userInfo[NotificationUserInfoKey.runbookURL] = sanitized
            }

            // Dashboard / Panel — Grafana only.
            if let alertmanager, alertmanager.isGrafana,
                let dashboardUID = alert.annotations["__dashboardUid__"]
            {
                let dashboardURL = "\(alertmanager.url)/d/\(dashboardUID)"
                userInfo[NotificationUserInfoKey.dashboardURL] = dashboardURL

                if let panelId = alert.annotations["__panelId__"] {
                    let panelURL = "\(alertmanager.url)/d/\(dashboardUID)?viewPanel=\(panelId)"
                    userInfo[NotificationUserInfoKey.panelURL] = panelURL
                }
            }

            // Assign a category whose action set exactly matches the URLs
            // present — so only reachable deep-links appear as buttons.
            content.categoryIdentifier = categoryIdentifier(for: userInfo)
            content.userInfo = userInfo

            let request = UNNotificationRequest(
                identifier: "alert-\(alert.fingerprint)",
                content: content,
                // `nil` trigger → deliver immediately.
                trigger: nil
            )

            center.add(request) { error in
                if let error = error {
                    print("Failed to send notification: \(error.localizedDescription)")
                }
            }
        }

        print("Sent \(alerts.count) notification(s) for filter '\(filter.name)'")
    }

    // MARK: - URL helpers

    /// Finds the alertmanager that produced `alert`.
    ///
    /// Any alertmanager whose cached list contains the fingerprint is
    /// accepted. Falls back to `nil` if nothing can be resolved (e.g.
    /// alert arrived very recently and the cache hasn't settled).
    private func resolveAlertmanager(
        for alert: GettableAlert, in alertmanagers: [Alertmanager]
    ) -> Alertmanager? {
        for alertmanager in alertmanagers {
            let cached = AlertsManager.shared.alertsByAlertmanager[alertmanager.id] ?? []
            if cached.contains(where: { $0.fingerprint == alert.fingerprint }) {
                return alertmanager
            }
        }
        return nil
    }

    /// Builds the silence URL for `alert` against `alertmanager`.
    /// Delegates to `AlertDeepLinks.silenceURL(for:alertmanager:resolvedDatasourceName:)`.
    private func buildSilenceURL(
        for alert: GettableAlert,
        alertmanager: Alertmanager,
        resolvedDatasourceName: String? = nil
    ) -> String? {
        AlertDeepLinks.silenceURL(
            for: alert,
            alertmanager: alertmanager,
            resolvedDatasourceName: resolvedDatasourceName
        )
    }

    /// Sanitizes a URL string via `AlertDeepLinks.sanitize(_:)`.
    private func sanitizeURL(_ urlString: String) -> String? {
        AlertDeepLinks.sanitize(urlString)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Called when the user taps an action button on a delivered notification.
    ///
    /// Reads the target URL from `userInfo` using the key that corresponds
    /// to the tapped action, then opens it with `NSWorkspace`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo

        // Use raw string literals here — the enums are MainActor-isolated
        // (project-wide default) and cannot be referenced from this
        // nonisolated delegate method.

        // Default tap (user tapped the notification body, not an action
        // button): open the alert-detail window.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            guard
                let fingerprint = userInfo["fingerprint"] as? String,
                let alertmanagerIDString = userInfo["alertmanagerID"] as? String,
                let alertmanagerID = UUID(uuidString: alertmanagerIDString)
            else { return }

            // Store the pending request, post a navigation notification (for
            // when ContentView is already alive), and trigger an immediate
            // fetch so the cache is populated before ContentView appears in
            // the cold-launch case.
            Task { @MainActor in
                NotificationService.shared.pendingAlertDetail = (fingerprint, alertmanagerID)

                // Post the navigation request — picked up by ContentView when
                // it's already mounted. Cold-launch path relies on
                // `consumePendingAlertDetail` from `onAppear` instead.
                NotificationCenter.default.post(
                    name: .openAlertDetail,
                    object: nil,
                    userInfo: [
                        "fingerprint": fingerprint,
                        "alertmanagerID": alertmanagerID,
                    ]
                )

                // Trigger an immediate fetch for the relevant alertmanager.
                guard
                    let context = NotificationService.shared.modelContext,
                    let alertmanager = try? context.fetch(FetchDescriptor<Alertmanager>())
                        .first(where: { $0.id == alertmanagerID })
                else { return }
                await AlertsManager.shared.fetchAlerts(for: alertmanager)
            }

            return
        }

        let urlKey: String
        switch response.actionIdentifier {
        case "OPEN_SOURCE":
            urlKey = "sourceURL"
        case "OPEN_SILENCE":
            urlKey = "silenceURL"
        case "OPEN_RUNBOOK":
            urlKey = "runbookURL"
        case "OPEN_DASHBOARD":
            urlKey = "dashboardURL"
        case "OPEN_PANEL":
            urlKey = "panelURL"
        default:
            return
        }

        guard let urlString = userInfo[urlKey] as? String,
            let url = URL(string: urlString)
        else { return }

        NSWorkspace.shared.open(url)
    }

    /// Allows notifications to be displayed even while the app is in the
    /// foreground (e.g. the menu bar popup is open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound])
    }
}
