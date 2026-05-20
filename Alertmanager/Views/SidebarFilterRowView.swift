//
//  SidebarFilterRowView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Sidebar row representing a single `Filter`.
///
/// Shows the filter's name and a trailing badge with the count of alerts
/// currently matching its predicates across every source alertmanager —
/// red when matches exist, green when empty. The count is recomputed
/// from `AlertsManager.shared` whenever any alertmanager's cache updates.
struct SidebarFilterRowView: View {
    /// The filter this row represents.
    let filter: Filter

    /// All alertmanagers in sidebar order. Used to give `AlertAggregator`
    /// a stable visitation order so dedup precedence matches what the user
    /// sees in the sidebar.
    @Query(sort: \Alertmanager.sortOrder) private var alertmanagers: [Alertmanager]

    /// Cached count of matching alerts shown in the badge.
    @State private var alertCount: Int = 0

    /// `true` while a fetch is in flight; drives the spinner.
    /// (Currently never set — left in place for parity with the
    /// alertmanager row's badge UI.)
    @State private var isLoading: Bool = false

    var body: some View {
        HStack {
            Text(filter.name)
                .font(.body)
                .accessibilityIdentifier("sidebar-filter-name-\(filter.name)")

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                // Capsule badge with the matching-alert count. Red signals
                // there are matches, green signals no matches.
                Text("\(alertCount)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(alertCount > 0 ? Color.red : Color.green)
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            updateAlertCount()
        }
        // Recompute on any alertmanager update — filters can span several
        // backends so we don't filter by id here.
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { _ in
            updateAlertCount()
        }
    }

    /// Recomputes `alertCount` from `AlertsManager`'s caches.
    ///
    /// Walks every alertmanager referenced by the filter, deduplicates
    /// alerts by `fingerprint` (the same alert can be produced by multiple
    /// alertmanagers), then applies the filter's predicates and stores the
    /// resulting count.
    private func updateAlertCount() {
        let filtered = AlertAggregator.alerts(
            for: filter,
            from: AlertsManager.shared.alertsByAlertmanager,
            orderedAlertmanagerIDs: alertmanagers.map(\.id)
        )
        alertCount = filtered.count
    }
}
