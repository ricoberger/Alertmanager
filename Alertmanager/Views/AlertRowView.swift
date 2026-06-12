//
//  AlertRowView.swift
//  Alertmanager
//

import SwiftUI

/// Single row representing one alert in the detail view or menu-bar popup.
///
/// The row collapses to a one-line summary (alertmanager name, alert name,
/// severity, relative start time) and expands on tap to show state,
/// receivers, start time, optional description, label badges, and a row of
/// deep-link buttons.
///
/// Deep-links handled here:
/// - **Source**: `alert.generatorURL` (sanitized via `openURL`).
/// - **Silence**: backend-specific URL built in `openSilenceURL`.
///   Standard Alertmanager uses `/#/silences/new?filter=...`; Grafana uses
///   `/alerting/silence/new?alertmanager=…&matcher=…`.
/// - **Runbook**: `annotations["runbook_url"]`.
/// - **Dashboard / Panel** (Grafana only): built from
///   `__dashboardUid__` / `__panelId__` annotations.
///
/// All URLs are opened via `NSWorkspace.shared.open(_:)`.
struct AlertRowView: View {
    /// The alert payload as returned by the Alertmanager API.
    let alert: GettableAlert

    /// The alertmanager this alert came from. Required for building
    /// silence/dashboard URLs and for the row's title prefix.
    let alertmanager: Alertmanager

    /// When `true`, the row uses a transparent background to blend into
    /// the `MenuBarExtra` popup chrome.
    var isMenuBar: Bool = false

    /// When `true`, the row starts in its expanded state. Used by
    /// `AlertDetailView` to render the alert fully expanded from the outset.
    var isExpanded: Bool = false

    /// Tracks whether the expanded detail section is shown.
    @State private var isExpandedState: Bool = false

    /// `true` while the datasource-name lookup for a Grafana silence URL is
    /// in flight. Used to disable the Silence button during the async fetch.
    @State private var isFetchingSilenceURL: Bool = false

    /// `true` while the cursor is over the row title; controls visibility of
    /// the hover-revealed "copy as markdown" icon next to the alert name.
    @State private var isHoveringTitle: Bool = false

    /// Briefly `true` after a successful copy. Flips the copy icon to a
    /// checkmark for a moment as confirmation feedback.
    @State private var didCopy: Bool = false

    /// User-configured label badge mappings, observed from `SettingsManager`.
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header: tap anywhere on the row to toggle expansion.
            // Implemented with `onTapGesture` rather than wrapping in a
            // Button so the nested copy Button below stays the sole hit
            // target inside its own bounds (nested SwiftUI Buttons fight
            // for clicks).
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(
                            settings.showAlertmanagerName
                                ? "[\(alertmanagerDisplayName)] \(alert.alertName)"
                                : alert.alertName
                        )
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                        Button(action: {
                            Task { await copyAlertAsMarkdown() }
                        }) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .opacity(isHoveringTitle || didCopy ? 1 : 0)
                        .help("Copy alert as Markdown")
                        .accessibilityLabel("Copy alert as Markdown")
                        .accessibilityIdentifier("alert-row-copy")
                    }
                    .onHover { isHoveringTitle = $0 }

                    if let subtitle = alert.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(isExpandedState ? nil : 1)
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    timeBadge
                    severityBadge
                    ForEach(customLabelBadges, id: \.0) { key, value, color in
                        Text(value.uppercased())
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(color)
                            .cornerRadius(4)
                    }
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    isExpandedState.toggle()
                }
            }

            if isExpandedState {
                // Expanded body: state/receivers/start, optional description,
                // label badges, and deep-link buttons.
                VStack(alignment: .leading, spacing: 20) {
                    Divider()

                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Alert State")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Text(alert.status.state.rawValue.capitalized)
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Receivers")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Text(alert.receivers.map { $0.name }.joined(separator: ", "))
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Started At")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Text(alert.startsAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)

                    if let description = alert.description.map({
                        $0.trimmingCharacters(in: .newlines)
                    }), !description.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Text(.init(description))
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal)
                    }

                    if !filteredLabels.isEmpty {
                        // Label badges, rendered with a custom flow layout
                        // so they wrap onto multiple lines as needed.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Labels")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal)

                            FlowLayout(spacing: 4) {
                                ForEach(
                                    Array(filteredLabels.sorted(by: { $0.key < $1.key })), id: \.key
                                ) { key, value in
                                    Text("\(key)=\(value)")
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    HStack(spacing: 8) {
                        // Deep-link button row. Buttons are conditionally
                        // shown based on which annotations / backend type
                        // are available for this alert.
                        if let generatorURL = alert.generatorURL {
                            Button(action: {
                                openURL(generatorURL)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                        .font(.system(size: 10))
                                    Text("Source")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button(action: {
                            Task {
                                isFetchingSilenceURL = true
                                await openSilenceURL()
                                isFetchingSilenceURL = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isFetchingSilenceURL {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "bell.slash.fill")
                                        .font(.system(size: 10))
                                }
                                Text("Silence")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFetchingSilenceURL)

                        if let runbookURL = alert.runbookURL {
                            Button(action: {
                                openURL(runbookURL)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "book.fill")
                                        .font(.system(size: 10))
                                    Text("Runbook")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if alertmanager.isGrafana,
                            let dashboardUID = alert.annotations["__dashboardUid__"]
                        {
                            Button(action: {
                                openDashboardURL(dashboardUID)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chart.bar.fill")
                                        .font(.system(size: 10))
                                    Text("Dashboard")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if alertmanager.isGrafana,
                            let dashboardUID = alert.annotations["__dashboardUid__"],
                            let panelId = alert.annotations["__panelId__"]
                        {
                            Button(action: {
                                openPanelURL(dashboardUID: dashboardUID, panelId: panelId)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.grid.2x2.fill")
                                        .font(.system(size: 10))
                                    Text("Panel")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(isMenuBar ? 0 : 1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExpandedState ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .accessibilityIdentifier("alert-row-\(alert.alertName)")
        .onAppear {
            isExpandedState = isExpanded
        }
    }

    /// Title prefix shown in the row header. Falls back from configured
    /// name → URL host → raw URL.
    private var alertmanagerDisplayName: String {
        if !alertmanager.name.isEmpty {
            return alertmanager.name
        }
        if let url = URL(string: alertmanager.url), let host = url.host {
            return host
        }
        return alertmanager.url
    }

    /// Color-coded severity pill rendered in the row header.
    private var severityBadge: some View {
        Text(alert.severity.uppercased())
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(severityColor)
            .cornerRadius(4)
    }

    /// Relative-time pill ("2m ago", etc.) rendered in the row header.
    private var timeBadge: some View {
        Text(relativeTime(from: alert.startsAt))
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray)
            .cornerRadius(4)
    }

    /// Maps a severity label to a visual color. Unknown values fall back
    /// to gray.
    private var severityColor: Color {
        switch alert.severity.lowercased() {
        case "critical":
            return .purple
        case "error":
            return .red
        case "warning":
            return .orange
        case "info":
            return .blue
        default:
            return .gray
        }
    }

    /// Resolves the user-configured label badge configs against this alert's
    /// labels. Returns tuples of (labelKey, labelValue, color) for each
    /// configured key that is present on the alert, preserving config order.
    private var customLabelBadges: [(String, String, Color)] {
        settings.labelBadgeConfigs.compactMap { config in
            guard !config.labelKey.isEmpty, let value = alert.labels[config.labelKey] else {
                return nil
            }
            return (config.labelKey, value, config.color)
        }
    }

    /// Labels suitable for badge display: hides `alertname` and
    /// `severity` (already shown in the header) and any Grafana-internal
    /// `__…__` labels.
    private var filteredLabels: [String: String] {
        alert.labels.filter { key, _ in
            key != "alertname" && key != "severity" && !(key.hasPrefix("__") && key.hasSuffix("__"))
        }
    }

    /// Formats `date` as a localized abbreviated relative string
    /// (e.g. "5m ago").
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Opens an arbitrary URL string in the user's default browser.
    ///
    /// Generator URLs from Prometheus often arrive with double-encoded
    /// query values (e.g. percent-encoded `=` and `"` inside a PromQL
    /// expression). This method rebuilds the URL via `URLComponents` and
    /// repeatedly percent-decodes each query value until it stabilizes,
    /// so the browser receives a clean URL.
    private func openURL(_ urlString: String) {
        print("Original URL string: \(urlString)")
        guard let sanitized = AlertDeepLinks.sanitize(urlString),
            let finalURL = URL(string: sanitized)
        else {
            print("Failed to parse or construct URL")
            return
        }
        print("Final URL: \(finalURL.absoluteString)")
        NSWorkspace.shared.open(finalURL)
    }

    /// Builds and opens the "create silence" URL for this alert.
    ///
    /// URL construction — including resolving the Grafana datasource name
    /// from its UID — is shared with the notification actions via
    /// `AlertmanagerService.resolveSilenceURL(for:in:)`. The URL is `nil`
    /// for a Grafana backend without a configured datasource.
    private func openSilenceURL() async {
        let service = AlertmanagerService()
        guard let urlString = await service.resolveSilenceURL(for: alert, in: alertmanager)
        else {
            print("No Grafana alertmanager configured")
            return
        }

        print("Opening silence URL: \(urlString)")
        openURL(urlString)
    }

    /// Opens the Grafana dashboard referenced by `__dashboardUid__`.
    private func openDashboardURL(_ dashboardUID: String) {
        let urlString = AlertDeepLinks.dashboardURL(
            alertmanager: alertmanager, dashboardUID: dashboardUID)
        print("Opening Grafana dashboard URL: \(urlString)")
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            print("Failed to create dashboard URL from: \(urlString)")
        }
    }

    /// Resolves the alertmanager's auth credentials, renders the alert as
    /// markdown, and writes the result to the general pasteboard.
    ///
    /// The markdown includes the alertmanager base URL and the resolved
    /// credentials so the recipient can reproduce the underlying API call.
    /// On success, the copy icon briefly switches to a checkmark.
    private func copyAlertAsMarkdown() async {
        let service = AlertmanagerService()
        let credentials = await service.resolveAuthCredentials(for: alertmanager)
        let markdown = AlertMarkdown.build(
            for: alert,
            alertmanager: alertmanager,
            authCredentials: credentials
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)

        didCopy = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        didCopy = false
    }

    /// Opens a specific Grafana panel using `__dashboardUid__` and
    /// `__panelId__` annotations.
    private func openPanelURL(dashboardUID: String, panelId: String) {
        let urlString = AlertDeepLinks.panelURL(
            alertmanager: alertmanager, dashboardUID: dashboardUID, panelId: panelId)
        print("Opening Grafana panel URL: \(urlString)")
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            print("Failed to create panel URL from: \(urlString)")
        }
    }
}

#Preview {
    let alertmanager = Alertmanager(
        name: "Test Alertmanager",
        url: "https://alertmanager.example.com",
        isGrafana: false,
        grafanaAlertmanager: "",
        authType: .none
    )

    return AlertRowView(
        alert: GettableAlert(
            annotations: [
                "summary": "High memory usage detected",
                "description":
                    "Memory usage is above 90% for the last 5 minutes on this server alertmanager",
                "runbook_url": "https://example.com/runbooks/high-memory-usage",
            ],
            receivers: [Receiver(name: "team-x")],
            fingerprint: "abc123",
            startsAt: Date().addingTimeInterval(-3600),
            updatedAt: Date(),
            endsAt: Date().addingTimeInterval(3600),
            status: AlertStatus(
                state: .active,
                silencedBy: [],
                inhibitedBy: [],
                mutedBy: []
            ),
            labels: [
                "alertname": "HighMemoryUsage",
                "severity": "warning",
                "alertmanager": "server-01.example.com",
                "job": "node-exporter",
                "namespace": "production",
                "pod": "api-server-1",
            ],
            generatorURL: "http://prometheus:9090/graph"
        ),
        alertmanager: alertmanager
    )
    .padding()
}
