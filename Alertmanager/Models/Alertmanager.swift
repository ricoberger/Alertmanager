//
//  Alertmanager.swift
//  Alertmanager
//

import Foundation
import SwiftData

/// A SwiftData-persisted configuration entry representing a single Alertmanager
/// backend the app should poll.
///
/// An `Alertmanager` describes either a standard Prometheus Alertmanager
/// instance or a Grafana-managed Alertmanager (when `isGrafana` is `true`).
/// In Grafana mode, `grafanaAlertmanagers` lists the per-datasource
/// Alertmanager names that should be queried via Grafana's proxied API.
@Model
final class Alertmanager {
    /// Stable identifier used as the key for polling timers, notification
    /// fingerprints, and import/export mapping.
    var id: UUID

    /// User-facing display name shown in the sidebar and notifications.
    var name: String

    /// Base URL of the Alertmanager (or Grafana) instance, without a trailing
    /// API path. API paths are appended by `AlertmanagerService`.
    var url: String

    /// When `true`, the URL points to a Grafana instance and alerts are
    /// fetched through Grafana's `/api/alertmanager/{name}/api/v2/alerts`
    /// endpoints for each entry in `grafanaAlertmanagers`.
    var isGrafana: Bool

    /// Names of the Grafana-managed Alertmanagers to query. Ignored when
    /// `isGrafana` is `false`. Each fetched alert is tagged with its source
    /// name to preserve correct silence/dashboard deep-links.
    var grafanaAlertmanagers: [String]

    /// Creation timestamp; primarily used for stable ordering as a tiebreaker.
    var timestamp: Date

    /// User-controlled position within the sidebar list. Lower values appear
    /// first.
    var sortOrder: Int

    /// JSON-encoded backing storage for `authType`.
    ///
    /// SwiftData cannot persist enums with associated values directly, so the
    /// value is encoded to `Data` and exposed through the `@Transient`
    /// computed `authType` accessor below.
    private var authTypeData: Data?

    /// Authentication strategy used when calling the Alertmanager API.
    ///
    /// Reads decode `authTypeData` lazily; writes re-encode the new value.
    /// Decode/encode failures fall back to `.none` and log via `print`.
    @Transient
    var authType: AuthenticationType {
        get {
            guard let data = authTypeData else { return .none }
            do {
                return try JSONDecoder().decode(AuthenticationType.self, from: data)
            } catch {
                print("Failed to decode authentication type: \(error)")
                return .none
            }
        }
        set {
            do {
                authTypeData = try JSONEncoder().encode(newValue)
            } catch {
                print("Failed to encode authentication type: \(error)")
                authTypeData = nil
            }
        }
    }

    /// Creates a new Alertmanager configuration.
    ///
    /// All parameters have sensible defaults so the initializer can be used
    /// to construct an empty draft for the form view, then populated via
    /// `@Bindable`.
    ///
    /// - Parameters:
    ///   - id: Stable identifier; defaults to a fresh `UUID`.
    ///   - name: Display name.
    ///   - url: Base URL of the backend.
    ///   - isGrafana: Whether this entry represents a Grafana-managed
    ///     Alertmanager.
    ///   - grafanaAlertmanagers: Grafana datasource names to query when
    ///     `isGrafana` is `true`.
    ///   - authType: Authentication strategy applied to outbound requests.
    ///   - timestamp: Creation date used for ordering tiebreaks.
    ///   - sortOrder: Position within the sidebar list.
    init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        isGrafana: Bool = false,
        grafanaAlertmanagers: [String] = [],
        authType: AuthenticationType = .none,
        timestamp: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isGrafana = isGrafana
        self.grafanaAlertmanagers = grafanaAlertmanagers
        self.timestamp = timestamp
        self.sortOrder = sortOrder
        self.authType = authType
    }
}

/// Authentication strategies supported when calling an Alertmanager backend.
///
/// Persisted indirectly through `Alertmanager.authTypeData` because SwiftData
/// does not natively persist enums with associated values.
enum AuthenticationType: Codable, Equatable, Hashable, Sendable {
    /// No authentication header is sent.
    case none

    /// HTTP Basic authentication using the supplied credentials. Encoded as
    /// `Authorization: Basic <base64(username:password)>`.
    case basicAuth(username: String, password: String)

    /// Bearer token authentication. The token is resolved at request time
    /// from the associated `TokenSource`.
    case tokenAuth(tokenSource: TokenSource)
}

/// Describes how a bearer token is obtained at request time.
///
/// Resolution happens in `AlertmanagerService` immediately before each
/// request, so file/command sources are re-evaluated on every poll and can
/// return rotated or short-lived tokens.
enum TokenSource: Codable, Equatable, Hashable, Sendable {
    /// Token value stored verbatim in SwiftData (plaintext).
    case direct(token: String)

    /// Absolute path to a file whose contents are the token. Trimmed of
    /// surrounding whitespace/newlines when read.
    case file(path: String)

    /// Shell command executed via `/bin/sh -c` whose stdout is used as the
    /// token. Requires the app to remain non-sandboxed.
    case command(command: String)
}
