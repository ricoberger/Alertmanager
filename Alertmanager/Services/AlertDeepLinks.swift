//
//  AlertDeepLinks.swift
//  Alertmanager
//

import Foundation

/// Pure, stateless namespace for building deep-link URLs related to alerts.
///
/// All methods are static and free of side-effects so they can be called from
/// both `AlertRowView` and `NotificationService` without code duplication,
/// and tested in isolation without any UI or system dependencies.
enum AlertDeepLinks {

    // MARK: - Source URL

    /// Rebuilds `urlString` via `URLComponents` with an iterative
    /// percent-decode pass on query values.
    ///
    /// Generator URLs from Prometheus often arrive with double-encoded query
    /// values (e.g. percent-encoded `=` and `"` inside a PromQL expression).
    /// This method rebuilds the URL and repeatedly percent-decodes each query
    /// value until it stabilises, so the browser receives a clean URL.
    ///
    /// Fragment components are intentionally dropped; only
    /// scheme/host/port/path/queryItems are preserved.
    ///
    /// - Returns: The sanitised URL string, or `nil` if `urlString` cannot be
    ///   parsed or the rebuilt URL cannot be serialised.
    static func sanitize(_ urlString: String) -> String? {
        guard let urlComponents = URLComponents(string: urlString) else { return nil }

        var newComponents = URLComponents()
        newComponents.scheme = urlComponents.scheme
        newComponents.host = urlComponents.host
        newComponents.port = urlComponents.port
        newComponents.path = urlComponents.path

        if let queryItems = urlComponents.queryItems {
            var newQueryItems: [URLQueryItem] = []
            for item in queryItems {
                if let value = item.value {
                    var decodedValue = value
                    while let decoded = decodedValue.removingPercentEncoding,
                        decoded != decodedValue
                    {
                        decodedValue = decoded
                    }
                    newQueryItems.append(URLQueryItem(name: item.name, value: decodedValue))
                } else {
                    newQueryItems.append(item)
                }
            }
            newComponents.queryItems = newQueryItems
        }

        return newComponents.url?.absoluteString
    }

    // MARK: - Silence URL

    /// Builds the "create silence" URL for `alert` against `alertmanager`.
    ///
    /// Two backend variants are supported:
    /// - **Grafana**: targets `{url}/alerting/silence/new` with one
    ///   `matcher=key%3Dvalue` query item per label (sorted by key), and an
    ///   `alertmanager=` parameter set to the datasource name.
    ///   Resolution priority: `resolvedDatasourceName` →
    ///   `alertmanager.grafanaAlertmanager` → `""`.
    /// - **Standard Alertmanager**: targets `{url}/#/silences/new` with a
    ///   single `filter={k1="v1", k2="v2"}` query value, percent-encoded.
    ///
    /// Both variants sort labels by key for deterministic output.
    ///
    /// - Parameters:
    ///   - alert: The alert whose labels are used to populate the silence matchers.
    ///   - alertmanager: The backend the alert was fetched from.
    ///   - resolvedDatasourceName: For Grafana, the human-readable datasource
    ///     name; when `nil`, falls back to the configured datasource UID.
    /// - Returns: The silence URL string.
    static func silenceURL(
        for alert: GettableAlert,
        alertmanager: Alertmanager,
        resolvedDatasourceName: String? = nil
    ) -> String {
        let sortedLabels = alert.labels.sorted { $0.key < $1.key }

        if alertmanager.isGrafana {
            let configuredUID =
                alertmanager.grafanaAlertmanager.isEmpty ? nil : alertmanager.grafanaAlertmanager
            let alertmanagerName =
                resolvedDatasourceName
                ?? configuredUID
                ?? ""
            var matchers: [String] = []
            for (key, value) in sortedLabels {
                if let encodedKey = key.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed),
                    let encodedValue = value.addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed)
                {
                    matchers.append("matcher=\(encodedKey)%3D\(encodedValue)")
                }
            }
            let matchersQuery = matchers.joined(separator: "&")
            return
                "\(alertmanager.url)/alerting/silence/new?alertmanager=\(alertmanagerName)&\(matchersQuery)"
        } else {
            var labelPairs: [String] = []
            for (key, value) in sortedLabels {
                if let encodedKey = key.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed),
                    let encodedValue = value.addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed)
                {
                    labelPairs.append("\(encodedKey)%3D%22\(encodedValue)%22")
                }
            }
            let filterEncoded = "%7B" + labelPairs.joined(separator: "%2C%20") + "%7D"
            return "\(alertmanager.url)/#/silences/new?filter=\(filterEncoded)"
        }
    }

    // MARK: - Dashboard / Panel (Grafana only)

    /// Builds the Grafana dashboard URL for `dashboardUID`.
    ///
    /// - Parameters:
    ///   - alertmanager: The Grafana backend.
    ///   - dashboardUID: The `__dashboardUid__` annotation value.
    /// - Returns: `"{url}/d/{dashboardUID}"`.
    static func dashboardURL(alertmanager: Alertmanager, dashboardUID: String) -> String {
        "\(alertmanager.url)/d/\(dashboardUID)"
    }

    /// Builds the Grafana panel URL for `dashboardUID` and `panelId`.
    ///
    /// - Parameters:
    ///   - alertmanager: The Grafana backend.
    ///   - dashboardUID: The `__dashboardUid__` annotation value.
    ///   - panelId: The `__panelId__` annotation value.
    /// - Returns: `"{url}/d/{dashboardUID}?viewPanel={panelId}"`.
    static func panelURL(alertmanager: Alertmanager, dashboardUID: String, panelId: String)
        -> String
    {
        "\(alertmanager.url)/d/\(dashboardUID)?viewPanel=\(panelId)"
    }
}
