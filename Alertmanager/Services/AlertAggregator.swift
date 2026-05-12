//
//  AlertAggregator.swift
//  Alertmanager
//

import Foundation

/// Pure, stateless helper for aggregating and filtering alerts from a
/// per-alertmanager cache dictionary.
///
/// The same "collect from multiple backends, deduplicate by fingerprint,
/// apply filter" pattern is needed in at least three places
/// (`SidebarFilterRowView`, `NotificationService`, `MenuBarContentView`).
/// Centralising it here keeps behaviour consistent and makes it directly
/// testable without touching any UI or system code.
enum AlertAggregator {

    /// Returns the set of alerts that match `filter`, gathered from the
    /// alertmanagers referenced by the filter.
    ///
    /// - Parameters:
    ///   - filter: The filter whose `selectedAlertmanagerIDs` and predicates
    ///     are used.
    ///   - cache: A dictionary mapping alertmanager IDs to their cached alert
    ///     list (e.g. `AlertsManager.shared.alertsByAlertmanager`).
    /// - Returns: Alerts matching every predicate in `filter`, deduplicated by
    ///   `fingerprint`, preserving the order they were encountered per
    ///   alertmanager.
    static func alerts(for filter: Filter, from cache: [UUID: [GettableAlert]]) -> [GettableAlert] {
        var allAlerts: [GettableAlert] = []
        var seenFingerprints: Set<String> = []

        for alertmanagerID in filter.selectedAlertmanagerIDs {
            let cached = cache[alertmanagerID] ?? []
            for alert in cached {
                if !seenFingerprints.contains(alert.fingerprint) {
                    seenFingerprints.insert(alert.fingerprint)
                    allAlerts.append(alert)
                }
            }
        }

        return filter.apply(to: allAlerts)
    }
}
