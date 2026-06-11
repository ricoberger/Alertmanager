//
//  AlertAggregator.swift
//  Alertmanager
//

import Foundation

/// Pure, stateless helper for aggregating and filtering alerts from a
/// per-alertmanager cache dictionary.
///
/// The same "collect from multiple backends, deduplicate by fingerprint,
/// apply filter" pattern is needed in `SidebarFilterRowView` and
/// `NotificationService`. Centralising it here keeps behaviour consistent
/// and makes it directly testable without touching any UI or system code.
enum AlertAggregator {

    /// Returns the set of alerts that match `filter`, gathered from the
    /// alertmanagers referenced by the filter.
    ///
    /// Alertmanagers are visited in the order given by
    /// `orderedAlertmanagerIDs` (typically the sidebar order, sorted by
    /// `Alertmanager.sortOrder`), so when the same alert fingerprint is
    /// produced by multiple alertmanagers the first one in sidebar order
    /// wins and later duplicates are dropped. `filter.selectedAlertmanagerIDs`
    /// is treated as an unordered set membership filter rather than the
    /// iteration order; an empty selection means "all alertmanagers"
    /// (see `Filter.includesAlertmanager(withID:)`).
    ///
    /// - Parameters:
    ///   - filter: The filter whose `selectedAlertmanagerIDs` and predicates
    ///     are used.
    ///   - cache: A dictionary mapping alertmanager IDs to their cached alert
    ///     list (e.g. `AlertsManager.shared.alertsByAlertmanager`).
    ///   - orderedAlertmanagerIDs: All known alertmanager IDs in their
    ///     sidebar order. Determines dedup precedence when the same
    ///     fingerprint appears in multiple alertmanagers.
    /// - Returns: Alerts matching every predicate in `filter`, deduplicated by
    ///   `fingerprint`.
    static func alerts(
        for filter: Filter,
        from cache: [UUID: [GettableAlert]],
        orderedAlertmanagerIDs: [UUID]
    ) -> [GettableAlert] {
        var allAlerts: [GettableAlert] = []
        var seenFingerprints: Set<String> = []

        for alertmanagerID in orderedAlertmanagerIDs
        where filter.includesAlertmanager(withID: alertmanagerID) {
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
