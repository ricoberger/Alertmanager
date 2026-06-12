//
//  AlertAggregator.swift
//  Alertmanager
//

import Foundation

/// Pure, stateless helper for aggregating and filtering alerts from a
/// per-alertmanager cache dictionary.
///
/// The same "collect from multiple backends, deduplicate by fingerprint,
/// apply filter" pattern is needed in `SidebarFilterRowView`,
/// `NotificationService`, `FilterDetailView`, and `MenuBarContentView`.
/// Centralising it here keeps behaviour consistent and makes it directly
/// testable without touching any UI or system code.
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

    /// Returns the alerts that match `filter` paired with the alertmanager
    /// they were collected from.
    ///
    /// Same contract as `alerts(for:from:orderedAlertmanagerIDs:)` — visit
    /// in sidebar order, deduplicate by fingerprint *before* applying the
    /// filter's predicates — but preserves which alertmanager won dedup for
    /// each alert so callers can build backend-specific deep links
    /// (`AlertRowView` needs the entity, not just the alert).
    ///
    /// Results are sorted newest-first because every consumer (filter
    /// detail view, menu bar popup) renders them in that order.
    ///
    /// - Parameters:
    ///   - filter: The filter whose `selectedAlertmanagerIDs` and predicates
    ///     are used.
    ///   - cache: A dictionary mapping alertmanager IDs to their cached alert
    ///     list (e.g. `AlertsManager.shared.alertsByAlertmanager`).
    ///   - orderedAlertmanagers: All known alertmanagers in their sidebar
    ///     order. Determines dedup precedence when the same fingerprint
    ///     appears in multiple alertmanagers.
    /// - Returns: Matching alerts paired with their dedup-winning source,
    ///   sorted by `startsAt` descending.
    static func alertsWithSources(
        for filter: Filter,
        from cache: [UUID: [GettableAlert]],
        orderedAlertmanagers: [Alertmanager]
    ) -> [(alert: GettableAlert, alertmanager: Alertmanager)] {
        var pairs: [(alert: GettableAlert, alertmanager: Alertmanager)] = []
        var seenFingerprints: Set<String> = []

        for alertmanager in orderedAlertmanagers
        where filter.includesAlertmanager(withID: alertmanager.id) {
            let cached = cache[alertmanager.id] ?? []
            for alert in cached where seenFingerprints.insert(alert.fingerprint).inserted {
                pairs.append((alert, alertmanager))
            }
        }

        // Apply the filter once over the deduplicated alerts, then keep the
        // pairing for the survivors. Fingerprints are unique after dedup,
        // so the set intersection is exact.
        let matching = Set(filter.apply(to: pairs.map(\.alert)).map(\.fingerprint))
        return
            pairs
            .filter { matching.contains($0.alert.fingerprint) }
            .sorted { $0.alert.startsAt > $1.alert.startsAt }
    }
}
