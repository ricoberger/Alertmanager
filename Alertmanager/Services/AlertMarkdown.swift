//
//  AlertMarkdown.swift
//  Alertmanager
//

import Foundation

/// Pure, stateless namespace for serialising an alert as a markdown snippet
/// suitable for pasting into chat, issue trackers, or runbooks.
///
/// The returned string always carries enough context for a reader to
/// reproduce a query against the originating Alertmanager: the backend's
/// base URL, the resolved authentication credentials (when supplied), the
/// alert's identifying labels, and the description/annotations.
///
/// All formatting is deterministic — labels and annotations are sorted by
/// key — so tests can compare snapshots without flake.
enum AlertMarkdown {

    /// Builds a markdown representation of `alert` for the given
    /// `alertmanager`.
    ///
    /// - Parameters:
    ///   - alert: The alert payload as returned by the Alertmanager API.
    ///   - alertmanager: The backend the alert was fetched from. Its `url`
    ///     is rendered into the output so the recipient knows which
    ///     instance the alert came from.
    ///   - authCredentials: Optional pre-resolved credentials string (e.g.
    ///     `"Basic user:pass"` or `"Bearer …"`). When `nil`, no credentials
    ///     line is emitted. Resolution is the caller's responsibility
    ///     because token sources may require asynchronous I/O.
    /// - Returns: A markdown string with a heading, metadata bullets, and
    ///   optional summary heading + description body, `Labels`, and
    ///   `Annotations` sections.
    static func build(
        for alert: GettableAlert,
        alertmanager: Alertmanager,
        authCredentials: String? = nil
    ) -> String {
        var lines: [String] = []

        lines.append("# \(alert.alertName)")
        lines.append("")

        if alertmanager.isGrafana {
            lines.append("- **Grafana URL:** \(alertmanager.url)")
        } else {
            lines.append("- **Alertmanager URL:** \(alertmanager.url)")
        }
        if let credentials = authCredentials, !credentials.isEmpty {
            if alertmanager.isGrafana {
                lines.append("- **Grafana Credentials:** \(credentials)")
            } else {
                lines.append("- **Alertmanager Credentials:** \(credentials)")
            }
        }
        if alertmanager.isGrafana, !alertmanager.grafanaAlertmanager.isEmpty {
            lines.append(
                "- **Grafana Alertmanager Datasource:** \(alertmanager.grafanaAlertmanager)")
        }
        lines.append("- **Severity:** \(alert.severity)")
        lines.append("- **State:** \(alert.status.state.rawValue.capitalized)")
        lines.append(
            "- **Started:** \(alert.startsAt.formatted(date: .abbreviated, time: .shortened))")
        if !alert.receivers.isEmpty {
            let names = alert.receivers.map { $0.name }.joined(separator: ", ")
            lines.append("- **Receivers:** \(names)")
        }
        if let generatorURL = alert.generatorURL, !generatorURL.isEmpty {
            lines.append("- **Source:** \(generatorURL)")
        }

        let summary = alert.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = alert.description?.trimmingCharacters(in: .whitespacesAndNewlines)

        // `summary` and `description` are surfaced as their own sections
        // above the generic Annotations list, so the generic list skips
        // both to avoid duplication.
        if let summary, !summary.isEmpty {
            lines.append("")
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
        }
        if let description, !description.isEmpty {
            lines.append("")
            lines.append("## Description")
            lines.append("")
            lines.append(description)
        }

        if !alert.labels.isEmpty {
            lines.append("")
            lines.append("## Labels")
            lines.append("")
            for (key, value) in alert.labels.sorted(by: { $0.key < $1.key }) {
                lines.append("- `\(key)`: `\(value)`")
            }
        }

        let remainingAnnotations = alert.annotations.filter { key, _ in
            key != "description" && key != "summary"
        }
        if !remainingAnnotations.isEmpty {
            lines.append("")
            lines.append("## Annotations")
            lines.append("")
            for (key, value) in remainingAnnotations.sorted(by: { $0.key < $1.key }) {
                lines.append("- `\(key)`: `\(value)`")
            }
        }

        return lines.joined(separator: "\n")
    }
}
