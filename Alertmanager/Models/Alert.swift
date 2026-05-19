//
//  Alert.swift
//  Alertmanager
//

import Foundation

/// An alert as returned by the Alertmanager `GET /api/v2/alerts` endpoint
/// (and by Grafana's `GET /api/alertmanager/{name}/api/v2/alerts` endpoint).
///
/// Conforms to `Identifiable` using `fingerprint` so SwiftUI lists can diff
/// alerts across refresh cycles without relying on array indices.
struct GettableAlert: Codable, Identifiable, Hashable {
    /// Stable identity derived from the alert's fingerprint, which Alertmanager
    /// computes from the alert's label set and remains constant across polls.
    var id: String { fingerprint }

    /// Free-form annotations attached to the alert (e.g. `summary`,
    /// `description`, `runbook_url`, and Grafana-specific keys like
    /// `__dashboardUid__` / `__panelId__`).
    let annotations: [String: String]

    /// Receivers (notification routes) the alert is currently being sent to.
    let receivers: [Receiver]

    /// Stable hash of the alert's label set; used as the unique identifier.
    let fingerprint: String

    /// Timestamp when the alert first became active.
    let startsAt: Date

    /// Timestamp of the most recent update from the source.
    let updatedAt: Date

    /// Timestamp when the alert is expected to end (or did end).
    let endsAt: Date

    /// Current status of the alert (state + silence/inhibition/mute info).
    let status: AlertStatus

    /// Label set identifying the alert (e.g. `alertname`, `severity`,
    /// `instance`, `job`). Used for display, filtering, and silence matchers.
    let labels: [String: String]

    /// URL to the originating system (typically Prometheus) that generated
    /// the alert. Used for the "Source" deep-link in `AlertRowView`.
    let generatorURL: String?
}

/// Status block describing an alert's lifecycle state and any active
/// silences, inhibitions, or mutes.
struct AlertStatus: Codable, Hashable {
    /// High-level state: `active`, `suppressed`, or `unprocessed`.
    let state: AlertState

    /// IDs of silences currently suppressing this alert.
    let silencedBy: [String]

    /// IDs of other alerts currently inhibiting this one.
    let inhibitedBy: [String]

    /// IDs of mute time intervals currently muting this alert. Optional
    /// because older Alertmanager versions don't emit this field.
    let mutedBy: [String]?

    /// Custom decoder that tolerates Alertmanager versions which omit
    /// `mutedBy` from the response payload.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(AlertState.self, forKey: .state)
        silencedBy = try container.decode([String].self, forKey: .silencedBy)
        inhibitedBy = try container.decode([String].self, forKey: .inhibitedBy)
        mutedBy = try container.decodeIfPresent([String].self, forKey: .mutedBy)
    }

    /// Memberwise initializer retained for tests and previews; the synthesized
    /// one is shadowed by the custom `init(from:)` above.
    init(state: AlertState, silencedBy: [String], inhibitedBy: [String], mutedBy: [String]? = nil) {
        self.state = state
        self.silencedBy = silencedBy
        self.inhibitedBy = inhibitedBy
        self.mutedBy = mutedBy
    }
}

/// Lifecycle state of an alert as reported by Alertmanager.
enum AlertState: String, Codable, Hashable {
    /// Alert has been received but not yet evaluated against the routing tree.
    case unprocessed
    /// Alert is firing and being routed to receivers.
    case active
    /// Alert is firing but suppressed by a silence or inhibition rule.
    case suppressed
}

/// Notification receiver (route target) the alert is being dispatched to.
struct Receiver: Codable, Hashable {
    /// Receiver name as configured in Alertmanager (e.g. `slack-critical`).
    let name: String
}

/// Convenience accessors over the raw label/annotation dictionaries so views
/// don't have to perform string lookups inline.
extension GettableAlert {
    /// Value of the conventional `alertname` label, with a sentinel fallback.
    var alertName: String {
        labels["alertname"] ?? "UnknownAlert"
    }

    /// Value of the conventional `severity` label, with a sentinel fallback.
    var severity: String {
        labels["severity"] ?? "unknown"
    }

    /// `true` if at least one silence is currently suppressing this alert.
    var isSilenced: Bool {
        !status.silencedBy.isEmpty
    }

    /// `true` if at least one inhibition rule is currently suppressing this alert.
    var isInhibited: Bool {
        !status.inhibitedBy.isEmpty
    }

    /// Short human-readable summary from the `summary` annotation.
    var summary: String? {
        annotations["summary"]
    }

    /// Longer human-readable description from the `description` annotation.
    var description: String? {
        annotations["description"]
    }

    /// Optional runbook link from the `runbook_url` annotation; surfaced as
    /// the "Runbook" deep-link in `AlertRowView`.
    var runbookURL: String? {
        annotations["runbook_url"]
    }

    /// Best-effort secondary line for list rows, preferring `summary`, then
    /// `description`, then the legacy `message` annotation.
    var subtitle: String? {
        summary ?? description ?? annotations["message"]
    }
}
