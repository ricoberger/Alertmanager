//
//  SidebarAlertmanagerRowView.swift
//  Alertmanager
//

import SwiftUI

/// Sidebar row representing a single `Alertmanager`.
///
/// Shows the alertmanager's display name (or URL fallback) alongside a
/// trailing badge: a spinner while the initial fetch is in flight, an
/// orange warning capsule when the most recent fetch failed, or a
/// colored alert-count capsule (red when there are alerts, green when
/// empty). State is mirrored from `AlertsManager.shared` and refreshed in
/// response to `.alertsDidUpdate` notifications scoped to this entry.
struct SidebarAlertmanagerRowView: View {
    /// The alertmanager this row represents.
    let alertmanager: Alertmanager

    /// Cached alert count for the badge.
    @State private var alertCount: Int = 0

    /// `true` while a fetch is in flight; drives the spinner.
    @State private var isLoading: Bool = false

    /// Localized error message from the most recent fetch, or `nil` when
    /// it succeeded. Drives the orange warning badge.
    @State private var errorMessage: String? = nil

    var body: some View {
        HStack {
            Text(alertmanager.name.isEmpty ? alertmanager.url : alertmanager.name)
                .font(.body)
                .accessibilityIdentifier("sidebar-alertmanager-name-\(alertmanager.name)")

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else if let errorMessage {
                // Orange warning badge signalling the most recent fetch
                // failed. The error message is surfaced via the help
                // tooltip so users can diagnose the issue on hover.
                //
                // The explicit accessibilityLabel makes the failure state
                // detectable by UI tests via the enclosing sidebar row's
                // combined accessibility label.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .help(errorMessage)
                    .accessibilityLabel("Fetch error")
            } else {
                // Capsule badge with the current alert count. Red signals
                // there are active alerts, green signals all-clear.
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
            // Ensure polling is running (idempotent) and seed local state.
            AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
            updateFromManager()
        }
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { notification in
            // The manager broadcasts updates for every alertmanager — only
            // refresh when the notification matches ours.
            if let alertmanagerId = notification.userInfo?["alertmanagerId"] as? UUID,
                alertmanagerId == alertmanager.id
            {
                updateFromManager()
            }
        }
    }

    /// Pulls the latest cached alert count, loading flag, and error
    /// message for this alertmanager from `AlertsManager.shared`.
    private func updateFromManager() {
        isLoading = AlertsManager.shared.isLoading(for: alertmanager)
        alertCount = AlertsManager.shared.getAlerts(for: alertmanager).count
        errorMessage = AlertsManager.shared.getError(for: alertmanager)
    }
}
