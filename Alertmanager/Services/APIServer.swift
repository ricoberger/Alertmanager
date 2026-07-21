//
//  APIServer.swift
//  Alertmanager
//

import Combine
import Foundation
import Network
import SwiftData

/// A minimal, dependency-free HTTP/1.1 server that exposes the app's alerts
/// (and the Analyze action) to other applications on the same machine.
///
/// Design constraints and decisions:
/// - **Transport**: hand-rolled HTTP/1.1 over Network.framework's
///   `NWListener` — the project intentionally has no SwiftPM dependencies.
///   Responses always set `Connection: close` (no keep-alive) to keep the
///   read/write loop trivial.
/// - **Bind**: `127.0.0.1` only (loopback). Same-machine consumers only.
/// - **Auth**: none. Acceptable because the socket is loopback-bound.
/// - **Port**: fixed `9093` in production (`APIServer.shared`). The `init`
///   accepts a port so tests can bind an ephemeral port (`0`).
/// - **CORS**: permissive (`Access-Control-Allow-Origin: *`) plus `OPTIONS`
///   preflight handling, so browser-based consumers can call the API.
/// - **JSON**: pretty-printed with sorted keys and ISO-8601 dates (matching
///   the app's decoder), so `curl`/browser output is readable and snapshot
///   tests are deterministic.
///
/// Isolation: the class is main-actor isolated (the project default) because
/// every handler touches main-actor state (`AlertsManager`, `AnalysisManager`,
/// `SettingsManager`, and the SwiftData `ModelContext`). The low-level socket
/// glue — accepting connections, reading a request, and writing a response —
/// is `nonisolated` and runs on a background queue; it hops to the main actor
/// only to route a fully-parsed request.
///
/// Requires the app to remain non-sandboxed only insofar as the Analyze action
/// it can trigger does (see `AnalysisManager`); binding a loopback listener
/// itself does not.
@MainActor
final class APIServer {
    /// Process-wide singleton used by the app. Binds the fixed port `9093`.
    static let shared = APIServer()

    /// Fixed production port. Collides with a local Prometheus Alertmanager if
    /// one runs on the same machine — accepted by design.
    static let defaultPort: UInt16 = 9093

    /// Serial background queue on which the listener and all connections run.
    nonisolated static let queue = DispatchQueue(label: "de.ricoberger.Alertmanager.APIServer")

    /// The port this instance binds. `0` lets the OS choose (used by tests).
    private let port: UInt16

    /// The active listener, or `nil` while stopped. Presence doubles as the
    /// running flag so `start()`/`stop()` are idempotent.
    private var listener: NWListener?

    /// The port the listener actually bound. Equals `port` unless `port` was
    /// `0`, in which case it holds the OS-assigned port once the listener is
    /// ready. Exposed for tests that bind an ephemeral port.
    private(set) var resolvedPort: UInt16?

    /// SwiftData context used to read `Alertmanager` / `Filter` entities.
    /// Created in `configure(with:)` from the shared container, mirroring
    /// `NotificationService`.
    private var modelContext: ModelContext?

    /// Stateless HTTP client, reused for the Grafana datasource-name lookup
    /// needed to build correct silence links.
    private let service = AlertmanagerService()

    /// Subscription to `SettingsManager.shared.$apiServerEnabled` installed by
    /// `startFromSettings()`. Retained so the server keeps reacting to the
    /// toggle for the app's lifetime.
    private var enabledCancellable: AnyCancellable?

    /// Creates a server bound to `port` (default `9093`). Tests pass `0` to
    /// bind an ephemeral port.
    init(port: UInt16 = APIServer.defaultPort) {
        self.port = port
    }

    // MARK: - Lifecycle

    /// Stores a `ModelContext` derived from the shared container so request
    /// handlers can read alertmanagers and filters. Call once from
    /// `AlertmanagerApp` after the container is available.
    func configure(with container: ModelContainer) {
        modelContext = ModelContext(container)
    }

    /// Subscribes to `SettingsManager.shared.apiServerEnabled` and
    /// starts/stops the server to match it, now and on every future change.
    ///
    /// This is deliberately view-independent (not tied to any `.onAppear`) so
    /// the server's lifecycle survives the main window closing. `@Published`
    /// delivers the current value on subscription, so the initial state is
    /// applied immediately. Idempotent — a second call is a no-op.
    func startFromSettings() {
        guard enabledCancellable == nil else { return }
        enabledCancellable = SettingsManager.shared.$apiServerEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.start()
                } else {
                    self.stop()
                }
            }
    }

    /// Binds the listener and ensures every alertmanager is being polled so
    /// the alert cache is warm regardless of UI state. Idempotent — a no-op
    /// while a listener is already active. Bind failures are logged only.
    func start() {
        guard listener == nil else { return }

        // Self-sufficient freshness: make sure the cache is being populated
        // for every configured alertmanager even if no UI has appeared yet.
        // `startMonitoring` is idempotent, so this never duplicates timers.
        for alertmanager in fetchAlertmanagers() {
            AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback-only: same-machine consumers, no network exposure.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port) ?? .any)

            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue
                    Task { @MainActor in self?.resolvedPort = bound }
                    print("APIServer: listening on 127.0.0.1:\(bound ?? 0)")
                case .failed(let error):
                    print("APIServer: listener failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: APIServer.queue)
            self.listener = listener
        } catch {
            // Per design: surface bind failures (e.g. port in use) via print
            // only, consistent with the codebase's logging style.
            print("APIServer: failed to start listener on port \(port): \(error.localizedDescription)")
        }
    }

    /// Cancels the listener and clears the running state. Safe to call when
    /// already stopped.
    func stop() {
        listener?.cancel()
        listener = nil
        resolvedPort = nil
    }

    // MARK: - Connection handling (nonisolated / background queue)

    /// Accepts a new connection, wires its lifecycle, and begins reading its
    /// request. Runs on `APIServer.queue`.
    nonisolated private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: APIServer.queue)
        readRequest(connection, buffer: Data())
    }

    /// Incrementally reads bytes until a full HTTP request (head plus any
    /// declared body) is available, then routes it. Reassembles across
    /// multiple `receive` callbacks. Runs on `APIServer.queue`.
    nonisolated private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [self] data, _, isComplete, error in

            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if error != nil {
                connection.cancel()
                return
            }

            // Wait until the head terminator (CRLFCRLF) has arrived.
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readRequest(connection, buffer: buffer)
                }
                return
            }

            let headData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
            guard var request = HTTPRequest.parseHead(headData) else {
                APIServer.send(.error(400, "Bad request"), on: connection)
                return
            }

            // Read the declared body (our POST endpoints carry none, but this
            // keeps the reader correct if a client sends one).
            let bodyStart = separator.upperBound
            let declared = request.contentLength
            let available = buffer.endIndex - bodyStart
            if available < declared {
                if isComplete {
                    connection.cancel()
                } else {
                    self.readRequest(connection, buffer: buffer)
                }
                return
            }
            if declared > 0 {
                request.body = buffer.subdata(in: bodyStart..<(bodyStart + declared))
            }

            // Hop to the main actor for routing (which touches app state),
            // then write the Sendable response back on the background queue.
            Task { [self] in
                let response = await self.route(request)
                APIServer.send(response, on: connection)
            }
        }
    }

    /// Serialises `response` to the wire (adding framing and CORS headers) and
    /// closes the connection. Runs on `APIServer.queue`.
    nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        // Permissive CORS to match the open, no-auth posture.
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "*"

        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrase(response.status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(
            content: out,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Routing (main actor)

    /// Routes a parsed request to a handler. `OPTIONS` short-circuits to a
    /// `204` (CORS headers are added by `send`). A matched path with the wrong
    /// method yields `405`; an unmatched path yields `404`.
    func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return .noContent()
        }

        guard let matched = APIRoute.match(request.pathComponents) else {
            return .error(404, "Not found")
        }
        guard request.method == matched.method else {
            return .error(405, "Method not allowed")
        }

        switch matched {
        case .index:
            return index()
        case .health:
            return .json(200, StatusResponse(status: "ok"))
        case .alertmanagers:
            return listAlertmanagers()
        case .filters:
            return listFilters()
        case .analyses:
            return listAnalyses()
        case .alertmanagerAlerts(let id):
            return await alertsForAlertmanager(id)
        case .filterAlerts(let id):
            return await alertsForFilter(id)
        case .analyze(let alertmanagerID, let fingerprint):
            return await analyze(alertmanagerID: alertmanagerID, fingerprint: fingerprint)
        case .analysis(let alertmanagerID, let fingerprint):
            return analysis(alertmanagerID: alertmanagerID, fingerprint: fingerprint)
        }
    }

    // MARK: - Handlers

    /// `GET /` (and `/api`) — a small discovery index of available endpoints.
    private func index() -> HTTPResponse {
        .json(200, IndexResponse.current)
    }

    /// `GET /api/alertmanagers` — configuration plus runtime health for every
    /// configured alertmanager (never any auth secrets).
    private func listAlertmanagers() -> HTTPResponse {
        let summaries = fetchAlertmanagers().map { am in
            APIAlertmanagerSummary(
                id: am.id,
                name: am.name,
                url: am.url,
                isGrafana: am.isGrafana,
                grafanaAlertmanager: am.grafanaAlertmanager,
                authType: Self.authTypeLabel(am.authType),
                lastRefresh: AlertsManager.shared.lastRefreshByAlertmanager[am.id] ?? nil,
                error: AlertsManager.shared.getError(for: am),
                isLoading: AlertsManager.shared.isLoading(for: am),
                alertCount: AlertsManager.shared.getAlerts(for: am).count)
        }
        return .json(200, summaries)
    }

    /// `GET /api/filters` — full filter configuration plus a computed count of
    /// currently-matching alerts.
    private func listFilters() -> HTTPResponse {
        let cache = AlertsManager.shared.alertsByAlertmanager
        let orderedIDs = fetchAlertmanagers().map(\.id)
        let summaries = fetchFilters().map { filter in
            let count = AlertAggregator.alerts(
                for: filter, from: cache, orderedAlertmanagerIDs: orderedIDs
            ).count
            return APIFilterSummary(
                id: filter.id,
                name: filter.name,
                selectedAlertmanagerIDs: filter.selectedAlertmanagerIDs,
                states: filter.states,
                receivers: filter.receivers,
                labelMatchers: filter.labelMatchers,
                notificationsEnabled: filter.notificationsEnabled,
                alertCount: count)
        }
        return .json(200, summaries)
    }

    /// `GET /api/analyses` — every existing analysis file on disk, with its
    /// alert name and start time parsed from the filename. Independent of the
    /// current alert cache, so historical analyses are listed too. Sorted
    /// newest-first by parsed start time.
    private func listAnalyses() -> HTTPResponse {
        let directory = AnalysisManager.shared.outputDirectory
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = urls.map {
            (
                name: $0.lastPathComponent,
                path: $0.path,
                markdown: try? String(contentsOf: $0, encoding: .utf8)
            )
        }
        return .json(200, Self.analysisFiles(from: entries))
    }

    /// `GET /api/alertmanagers/{id}/alerts` — the cached alerts for one
    /// alertmanager, enriched with markdown, actions, and analysis state.
    private func alertsForAlertmanager(_ idString: String) async -> HTTPResponse {
        guard let alertmanager = fetchAlertmanager(id: idString) else {
            return .error(404, "Alertmanager not found")
        }
        let alerts = AlertsManager.shared.getAlerts(for: alertmanager)
        var datasourceNameCache: [UUID: String?] = [:]
        var dtos: [APIAlert] = []
        for alert in alerts {
            dtos.append(
                await makeAlertDTO(
                    alert: alert, alertmanager: alertmanager, cache: &datasourceNameCache))
        }
        return .json(200, dtos)
    }

    /// `GET /api/filters/{id}/alerts` — the alerts matching one filter,
    /// aggregated and deduplicated across its alertmanagers, each paired with
    /// its dedup-winning source alertmanager.
    private func alertsForFilter(_ idString: String) async -> HTTPResponse {
        guard let filter = fetchFilter(id: idString) else {
            return .error(404, "Filter not found")
        }
        let orderedAlertmanagers = fetchAlertmanagers()
        let pairs = AlertAggregator.alertsWithSources(
            for: filter,
            from: AlertsManager.shared.alertsByAlertmanager,
            orderedAlertmanagers: orderedAlertmanagers)

        var datasourceNameCache: [UUID: String?] = [:]
        var dtos: [APIAlert] = []
        for pair in pairs {
            dtos.append(
                await makeAlertDTO(
                    alert: pair.alert, alertmanager: pair.alertmanager,
                    cache: &datasourceNameCache))
        }
        return .json(200, dtos)
    }

    /// `POST /api/alertmanagers/{id}/alerts/{fingerprint}/analyze` — triggers
    /// the Analyze command for one alert firing.
    ///
    /// Status codes: `202` when a run starts, `409` when one is already
    /// running (never starting a second — `AnalysisManager` dedups by
    /// filename, and awaiting `analyze` below inserts the in-flight name
    /// before its first suspension point, so a concurrent request observes
    /// `isRunning == true`), `422` when no command is configured, `404` when
    /// the alertmanager or alert cannot be resolved.
    private func analyze(alertmanagerID: String, fingerprint: String) async -> HTTPResponse {
        let alertmanager = fetchAlertmanager(id: alertmanagerID)
        let alert = alertmanager.flatMap { cachedAlert(withFingerprint: fingerprint, in: $0) }

        let commandConfigured = !SettingsManager.shared.analyzeCommand
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let running = alert.map { AnalysisManager.shared.isRunning(for: $0) } ?? false

        let status = Self.analyzeStatus(
            alertResolved: alert != nil, commandConfigured: commandConfigured, running: running)

        switch status {
        case 404:
            return .error(404, alertmanager == nil ? "Alertmanager not found" : "Alert not found")
        case 422:
            return .error(422, "No analyze command configured")
        case 409:
            guard let alert else { return .error(404, "Alert not found") }
            return .json(409, analysisState(for: alert, commandConfigured: true))
        default:
            guard let alert, let alertmanager else { return .error(404, "Alert not found") }
            // Awaiting is intentional: `analyze` inserts the in-flight filename
            // synchronously before its first `await`, so on the serialized main
            // actor a concurrent POST for the same firing takes the `409`
            // branch above instead of spawning a second process.
            await AnalysisManager.shared.analyze(for: alert, alertmanager: alertmanager)
            return .json(202, analysisState(for: alert, commandConfigured: true))
        }
    }

    /// `GET /api/alertmanagers/{id}/alerts/{fingerprint}/analysis` — the
    /// current analysis state plus the analysis file contents (if any). `404`
    /// only when the alertmanager or alert cannot be resolved.
    private func analysis(alertmanagerID: String, fingerprint: String) -> HTTPResponse {
        guard let alertmanager = fetchAlertmanager(id: alertmanagerID) else {
            return .error(404, "Alertmanager not found")
        }
        guard let alert = cachedAlert(withFingerprint: fingerprint, in: alertmanager) else {
            return .error(404, "Alert not found")
        }

        let commandConfigured = !SettingsManager.shared.analyzeCommand
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let exists = AnalysisManager.shared.analysisExists(for: alert)
        let markdown =
            exists
            ? try? String(contentsOf: AnalysisManager.shared.fileURL(for: alert), encoding: .utf8)
            : nil

        return .json(
            200,
            APIAnalysisResponse(
                available: commandConfigured,
                exists: exists,
                running: AnalysisManager.shared.isRunning(for: alert),
                markdown: markdown,
                filePath: AnalysisManager.shared.fileURL(for: alert).path))
    }

    // MARK: - DTO construction

    /// Builds the enriched API representation of one alert, resolving its
    /// action URLs (with a per-request cache for the Grafana datasource-name
    /// lookup) and analysis state. Credentials are deliberately omitted from
    /// the markdown.
    private func makeAlertDTO(
        alert: GettableAlert, alertmanager: Alertmanager, cache: inout [UUID: String?]
    ) async -> APIAlert {
        let silence = await resolveSilence(for: alert, alertmanager: alertmanager, cache: &cache)
        let actions = APIActions.build(for: alert, alertmanager: alertmanager, silence: silence)
        // Credentials omitted (authCredentials: nil): the API is unauthenticated.
        let markdown = AlertMarkdown.build(for: alert, alertmanager: alertmanager)

        return APIAlert(
            fingerprint: alert.fingerprint,
            alertName: alert.alertName,
            severity: alert.severity,
            state: alert.status.state,
            summary: alert.subtitle,
            alertmanager: APIAlertmanagerRef(id: alertmanager.id, name: alertmanager.name),
            markdown: markdown,
            actions: actions,
            analysis: analysisState(for: alert),
            raw: alert)
    }

    /// Resolves the silence URL for `alert`, looking up a Grafana datasource
    /// name at most once per alertmanager per request (memoized in `cache`).
    /// Mirrors `AlertmanagerService.resolveSilenceURL`, including returning
    /// `nil` for a Grafana backend without a configured datasource.
    private func resolveSilence(
        for alert: GettableAlert, alertmanager: Alertmanager, cache: inout [UUID: String?]
    ) async -> String? {
        guard alertmanager.isGrafana else {
            return AlertDeepLinks.silenceURL(for: alert, alertmanager: alertmanager)
        }

        let configuredUID =
            alertmanager.grafanaAlertmanager.isEmpty ? nil : alertmanager.grafanaAlertmanager
        guard let uid = configuredUID else {
            return nil
        }

        let resolvedName: String?
        if uid == "grafana" {
            resolvedName = nil  // built-in datasource: used verbatim downstream
        } else if let cached = cache[alertmanager.id] {
            resolvedName = cached
        } else {
            let name = await service.fetchDatasourceName(for: uid, in: alertmanager)
            cache[alertmanager.id] = name
            resolvedName = name
        }

        return AlertDeepLinks.silenceURL(
            for: alert, alertmanager: alertmanager, resolvedDatasourceName: resolvedName)
    }

    /// Current analysis state for `alert`. `commandConfigured` may be supplied
    /// to avoid re-reading the setting when the caller already knows it.
    private func analysisState(for alert: GettableAlert, commandConfigured: Bool? = nil)
        -> APIAnalysisState
    {
        let available =
            commandConfigured
            ?? !SettingsManager.shared.analyzeCommand
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return APIAnalysisState(
            available: available,
            exists: AnalysisManager.shared.analysisExists(for: alert),
            running: AnalysisManager.shared.isRunning(for: alert))
    }

    // MARK: - SwiftData access

    /// Fetches all alertmanagers ordered by `sortOrder`, or `[]` if the
    /// context is unavailable / the fetch fails.
    private func fetchAlertmanagers() -> [Alertmanager] {
        guard let modelContext else { return [] }
        return (try? modelContext.fetch(
            FetchDescriptor<Alertmanager>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    /// Fetches all filters ordered by `sortOrder`, or `[]` on failure.
    private func fetchFilters() -> [Filter] {
        guard let modelContext else { return [] }
        return (try? modelContext.fetch(
            FetchDescriptor<Filter>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
    }

    /// Resolves an alertmanager by its UUID string, or `nil` if the string is
    /// malformed or no such entity exists.
    private func fetchAlertmanager(id idString: String) -> Alertmanager? {
        guard let id = UUID(uuidString: idString) else { return nil }
        return fetchAlertmanagers().first { $0.id == id }
    }

    /// Resolves a filter by its UUID string, or `nil` if malformed / missing.
    private func fetchFilter(id idString: String) -> Filter? {
        guard let id = UUID(uuidString: idString) else { return nil }
        return fetchFilters().first { $0.id == id }
    }

    /// Finds a cached alert for `alertmanager` by fingerprint.
    private func cachedAlert(withFingerprint fingerprint: String, in alertmanager: Alertmanager)
        -> GettableAlert?
    {
        AlertsManager.shared.getAlerts(for: alertmanager).first { $0.fingerprint == fingerprint }
    }

    /// Maps an `AuthenticationType` to a non-secret label for the API.
    nonisolated static func authTypeLabel(_ authType: AuthenticationType) -> String {
        switch authType {
        case .none: return "none"
        case .basicAuth: return "basic"
        case .tokenAuth: return "token"
        }
    }

    /// Pure builder for `GET /api/analyses`: parses each `(name, path)` entry,
    /// drops names that don't match the analysis-file pattern, and returns the
    /// results sorted newest-first by parsed start time. Extracted so the
    /// filtering/sorting is unit-testable without touching the filesystem.
    nonisolated static func analysisFiles(from entries: [(name: String, path: String, markdown: String?)])
        -> [APIAnalysisFile]
    {
        entries
            .compactMap { entry -> APIAnalysisFile? in
                guard let parsed = AnalysisManager.parseFileName(entry.name) else { return nil }
                return APIAnalysisFile(
                    alertName: parsed.alertName,
                    startsAt: parsed.startsAt,
                    filePath: entry.path,
                    markdown: entry.markdown)
            }
            .sorted { $0.startsAt > $1.startsAt }
    }

    /// Pure decision for `POST .../analyze`, returning the HTTP status code:
    /// `404` when the alert can't be resolved, `422` when no command is
    /// configured, `409` when a run is already in flight, `202` to start one.
    /// Extracted so the branching is unit-testable without touching the
    /// filesystem or singletons.
    nonisolated static func analyzeStatus(
        alertResolved: Bool, commandConfigured: Bool, running: Bool
    ) -> Int {
        if !alertResolved { return 404 }
        if !commandConfigured { return 422 }
        if running { return 409 }
        return 202
    }
}
