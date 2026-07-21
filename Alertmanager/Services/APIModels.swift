//
//  APIModels.swift
//  Alertmanager
//
//  Transport primitives, route matching, and response DTOs for `APIServer`.
//  Everything here is pure and free of app state so it can be unit-tested
//  without a running listener. The `nonisolated` annotations let the socket
//  layer (which runs off the main actor) parse requests and serialise
//  responses directly.
//

import Foundation

// MARK: - HTTP request

/// A parsed HTTP request. Value type so it can cross from the background
/// socket queue to the main actor for routing.
struct HTTPRequest: Sendable, Equatable {
    /// Uppercased HTTP method (e.g. `GET`, `POST`, `OPTIONS`).
    let method: String
    /// Request path without the query string (e.g. `/api/alertmanagers`).
    let path: String
    /// Percent-decoded, non-empty path segments (e.g. `["api", "alertmanagers"]`).
    let pathComponents: [String]
    /// Query parameters, if any.
    let query: [String: String]
    /// Header fields keyed by lowercased name.
    let headers: [String: String]
    /// Request body (empty for the read-only and no-body endpoints here).
    var body: Data

    /// Declared body length from the `Content-Length` header, or `0`.
    var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

    /// Parses the request head (everything before the CRLFCRLF terminator)
    /// into an `HTTPRequest` with an empty body. Returns `nil` when the head
    /// is not valid UTF-8 or the request line is malformed.
    nonisolated static func parseHead(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var path = target
        var query: [String: String] = [:]
        if let components = URLComponents(string: target) {
            path = components.path
            for item in components.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
        }

        let pathComponents = path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                headers[key] = value
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            pathComponents: pathComponents,
            query: query,
            headers: headers,
            body: Data())
    }
}

// MARK: - HTTP response

/// A response ready to serialise. Value type so handlers on the main actor can
/// hand it back to the socket layer.
struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    /// Builds a JSON response (pretty-printed, sorted keys, ISO-8601 dates).
    /// Encoding failures degrade to a `500` error body rather than throwing.
    nonisolated static func json<T: Encodable>(_ status: Int = 200, _ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let body = try? encoder.encode(value) {
            return HTTPResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body)
        }
        return error(500, "Failed to encode response")
    }

    /// Builds a JSON error envelope `{"error": "<message>"}`.
    nonisolated static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body =
            (try? encoder.encode(APIErrorBody(error: message)))
            ?? Data(#"{"error":"unknown"}"#.utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body)
    }

    /// A `204 No Content` response (used for CORS preflight).
    nonisolated static func noContent() -> HTTPResponse {
        HTTPResponse(status: 204, headers: [:], body: Data())
    }

    /// Maps a status code to its reason phrase for the status line.
    nonisolated static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 422: return "Unprocessable Content"
        case 500: return "Internal Server Error"
        default: return ""
        }
    }
}

// MARK: - Routing

/// The set of routes the API understands, matched from path components alone.
/// Method validation is applied separately so a known path with the wrong
/// verb can yield `405` rather than `404`.
enum APIRoute: Equatable, Sendable {
    case index
    case health
    case alertmanagers
    case filters
    case analyses
    case alertmanagerAlerts(id: String)
    case filterAlerts(id: String)
    case analyze(alertmanagerID: String, fingerprint: String)
    case analysis(alertmanagerID: String, fingerprint: String)

    /// The HTTP method this route requires.
    var method: String {
        if case .analyze = self { return "POST" }
        return "GET"
    }

    /// Matches percent-decoded path components to a route, or `nil` when no
    /// route's shape matches.
    nonisolated static func match(_ c: [String]) -> APIRoute? {
        switch c.count {
        case 0:
            return .index
        case 1:
            if c[0] == "api" { return .index }
            if c[0] == "healthz" { return .health }
            return nil
        case 2:
            if c == ["api", "alertmanagers"] { return .alertmanagers }
            if c == ["api", "filters"] { return .filters }
            if c == ["api", "analyses"] { return .analyses }
            return nil
        case 4:
            if c[0] == "api", c[1] == "alertmanagers", c[3] == "alerts" {
                return .alertmanagerAlerts(id: c[2])
            }
            if c[0] == "api", c[1] == "filters", c[3] == "alerts" {
                return .filterAlerts(id: c[2])
            }
            return nil
        case 6:
            guard c[0] == "api", c[1] == "alertmanagers", c[3] == "alerts" else { return nil }
            if c[5] == "analyze" {
                return .analyze(alertmanagerID: c[2], fingerprint: c[4])
            }
            if c[5] == "analysis" {
                return .analysis(alertmanagerID: c[2], fingerprint: c[4])
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Response DTOs

/// JSON error envelope body.
struct APIErrorBody: Encodable {
    let error: String
}

/// `GET /healthz` body.
struct StatusResponse: Encodable {
    let status: String
}

/// `GET /` discovery index.
struct IndexResponse: Encodable {
    struct Endpoint: Encodable {
        let method: String
        let path: String
        let description: String
    }

    let name: String
    let endpoints: [Endpoint]

    /// The static endpoint listing returned by the index route.
    static let current = IndexResponse(
        name: "Alertmanager API",
        endpoints: [
            Endpoint(method: "GET", path: "/healthz", description: "Health check"),
            Endpoint(
                method: "GET", path: "/api/alertmanagers",
                description: "List configured alertmanagers"),
            Endpoint(
                method: "GET", path: "/api/alertmanagers/{id}/alerts",
                description: "Alerts for an alertmanager"),
            Endpoint(
                method: "POST", path: "/api/alertmanagers/{id}/alerts/{fingerprint}/analyze",
                description: "Trigger the Analyze action for an alert"),
            Endpoint(
                method: "GET", path: "/api/alertmanagers/{id}/alerts/{fingerprint}/analysis",
                description: "Fetch the analysis for an alert"),
            Endpoint(method: "GET", path: "/api/filters", description: "List configured filters"),
            Endpoint(
                method: "GET", path: "/api/filters/{id}/alerts",
                description: "Alerts matching a filter"),
            Endpoint(
                method: "GET", path: "/api/analyses",
                description: "List all existing analysis files"),
        ])
}

/// One entry in `GET /api/alertmanagers`: configuration (auth *type* only, no
/// secrets) plus runtime health.
struct APIAlertmanagerSummary: Encodable {
    let id: UUID
    let name: String
    let url: String
    let isGrafana: Bool
    let grafanaAlertmanager: String
    let authType: String
    let lastRefresh: Date?
    let error: String?
    let isLoading: Bool
    let alertCount: Int
}

/// One entry in `GET /api/filters`: full configuration plus a computed count
/// of currently-matching alerts.
struct APIFilterSummary: Encodable {
    let id: UUID
    let name: String
    let selectedAlertmanagerIDs: [UUID]
    let states: [AlertState]
    let receivers: [String]
    let labelMatchers: [LabelMatcher]
    let notificationsEnabled: Bool
    let alertCount: Int
}

/// Reference to the source alertmanager an alert was collected from.
struct APIAlertmanagerRef: Encodable {
    let id: UUID
    let name: String
}

/// Deep-link actions for an alert. Only the keys that apply are emitted
/// (nil optionals are omitted by the synthesized encoder).
struct APIActions: Encodable {
    let source: String?
    let silence: String?
    let runbook: String?
    let dashboard: String?
    let panel: String?

    /// Builds the action set for `alert`. The silence URL is resolved by the
    /// caller (it may require async I/O for Grafana) and passed in.
    nonisolated static func build(
        for alert: GettableAlert, alertmanager: Alertmanager, silence: String?
    ) -> APIActions {
        var source: String?
        if let generator = alert.generatorURL, !generator.isEmpty {
            source = AlertDeepLinks.sanitize(generator)
        }

        var runbook: String?
        if let url = alert.runbookURL, !url.isEmpty {
            runbook = url
        }

        var dashboard: String?
        var panel: String?
        if alertmanager.isGrafana,
            let dashboardUID = alert.annotations["__dashboardUid__"], !dashboardUID.isEmpty
        {
            dashboard = AlertDeepLinks.dashboardURL(
                alertmanager: alertmanager, dashboardUID: dashboardUID)
            if let panelId = alert.annotations["__panelId__"], !panelId.isEmpty {
                panel = AlertDeepLinks.panelURL(
                    alertmanager: alertmanager, dashboardUID: dashboardUID, panelId: panelId)
            }
        }

        return APIActions(
            source: source, silence: silence, runbook: runbook, dashboard: dashboard, panel: panel)
    }
}

/// Analysis state carried inline with each alert in list responses.
struct APIAnalysisState: Encodable {
    /// Whether an analyze command is configured at all.
    let available: Bool
    /// Whether an analysis file already exists for this alert firing.
    let exists: Bool
    /// Whether an analysis run is currently in flight for this firing.
    let running: Bool
}

/// `GET .../analysis` body. `markdown` is always present, explicitly `null`
/// when no analysis file exists yet.
struct APIAnalysisResponse: Encodable {
    let available: Bool
    let exists: Bool
    let running: Bool
    let markdown: String?
    /// Absolute path to the analysis file for this alert firing (always
    /// present, even when the file doesn't exist yet).
    let filePath: String

    private enum CodingKeys: String, CodingKey {
        case available, exists, running, markdown, filePath
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(exists, forKey: .exists)
        try container.encode(running, forKey: .running)
        try container.encode(filePath, forKey: .filePath)
        // Emit an explicit null rather than omitting the key.
        if let markdown {
            try container.encode(markdown, forKey: .markdown)
        } else {
            try container.encodeNil(forKey: .markdown)
        }
    }
}

/// One alert in a list response: minimal curated fields, derived markdown /
/// actions / analysis state, and the untouched raw payload.
struct APIAlert: Encodable {
    let fingerprint: String
    let alertName: String
    let severity: String
    let state: AlertState
    /// Best-effort human-readable summary line, matching the app's row
    /// subtitle: `summary` annotation, falling back to `description`, then
    /// the legacy `message` annotation. Omitted when none are present.
    let summary: String?
    let alertmanager: APIAlertmanagerRef
    let markdown: String
    let actions: APIActions
    let analysis: APIAnalysisState
    let raw: GettableAlert
}

/// One entry in `GET /api/analyses`: an existing analysis file on disk, with
/// its components parsed from the filename and its Markdown contents.
struct APIAnalysisFile: Encodable {
    /// Sanitized alert name parsed from the filename (see
    /// `AnalysisManager.parseFileName`).
    let alertName: String
    /// Alert firing start time parsed from the filename timestamp.
    let startsAt: Date
    /// Absolute path to the analysis file on disk.
    let filePath: String
    /// The file's Markdown contents, or `null` if it could not be read.
    let markdown: String?

    private enum CodingKeys: String, CodingKey {
        case alertName, startsAt, filePath, markdown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alertName, forKey: .alertName)
        try container.encode(startsAt, forKey: .startsAt)
        try container.encode(filePath, forKey: .filePath)
        // Emit an explicit null rather than omitting the key.
        if let markdown {
            try container.encode(markdown, forKey: .markdown)
        } else {
            try container.encodeNil(forKey: .markdown)
        }
    }
}
