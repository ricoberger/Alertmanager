//
//  APIServerTests.swift
//  AlertmanagerTests
//

import Foundation
import SwiftData
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlert(
    fingerprint: String = "fp",
    labels: [String: String] = [:],
    annotations: [String: String] = [:],
    generatorURL: String? = nil
) -> GettableAlert {
    GettableAlert(
        annotations: annotations,
        receivers: [],
        fingerprint: fingerprint,
        startsAt: Date(),
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: .active, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: generatorURL)
}

private func makeAlertmanager(
    name: String = "Test",
    url: String = "http://am.example.com",
    isGrafana: Bool = false,
    grafanaAlertmanager: String = ""
) -> Alertmanager {
    Alertmanager(
        name: name, url: url, isGrafana: isGrafana, grafanaAlertmanager: grafanaAlertmanager)
}

// MARK: - HTTPRequest.parseHead

@Suite("HTTPRequest.parseHead")
struct HTTPRequestParseTests {

    @Test("Parses method, path, query, and headers")
    func parsesBasics() {
        let head = "GET /api/alertmanagers?foo=bar HTTP/1.1\r\nHost: example\r\nContent-Length: 0"
        let request = HTTPRequest.parseHead(Data(head.utf8))
        #expect(request?.method == "GET")
        #expect(request?.path == "/api/alertmanagers")
        #expect(request?.pathComponents == ["api", "alertmanagers"])
        #expect(request?.query["foo"] == "bar")
        #expect(request?.headers["host"] == "example")
        #expect(request?.contentLength == 0)
    }

    @Test("Header names are lowercased")
    func lowercasesHeaderNames() {
        let head = "GET / HTTP/1.1\r\nContent-Length: 12"
        let request = HTTPRequest.parseHead(Data(head.utf8))
        #expect(request?.headers["content-length"] == "12")
        #expect(request?.contentLength == 12)
    }

    @Test("Root path produces empty path components")
    func rootPath() {
        let request = HTTPRequest.parseHead(Data("GET / HTTP/1.1".utf8))
        #expect(request?.pathComponents == [])
    }

    @Test("Percent-encoded path components are decoded")
    func decodesPercentEncoding() {
        let request = HTTPRequest.parseHead(Data("GET /api/a%20b HTTP/1.1".utf8))
        #expect(request?.pathComponents == ["api", "a b"])
    }

    @Test("Malformed request line returns nil")
    func malformedReturnsNil() {
        #expect(HTTPRequest.parseHead(Data("garbage".utf8)) == nil)
    }
}

// MARK: - APIRoute.match

@Suite("APIRoute.match")
struct APIRouteMatchTests {

    @Test("Index for empty and /api")
    func index() {
        #expect(APIRoute.match([]) == .index)
        #expect(APIRoute.match(["api"]) == .index)
    }

    @Test("Health route")
    func health() {
        #expect(APIRoute.match(["healthz"]) == .health)
    }

    @Test("List routes")
    func lists() {
        #expect(APIRoute.match(["api", "alertmanagers"]) == .alertmanagers)
        #expect(APIRoute.match(["api", "filters"]) == .filters)
    }

    @Test("Alert list routes carry the id")
    func alertLists() {
        #expect(
            APIRoute.match(["api", "alertmanagers", "AM", "alerts"])
                == .alertmanagerAlerts(id: "AM"))
        #expect(APIRoute.match(["api", "filters", "F", "alerts"]) == .filterAlerts(id: "F"))
    }

    @Test("Analyze and analysis routes carry id and fingerprint")
    func analyzeAndAnalysis() {
        #expect(
            APIRoute.match(["api", "alertmanagers", "AM", "alerts", "FP", "analyze"])
                == .analyze(alertmanagerID: "AM", fingerprint: "FP"))
        #expect(
            APIRoute.match(["api", "alertmanagers", "AM", "alerts", "FP", "analysis"])
                == .analysis(alertmanagerID: "AM", fingerprint: "FP"))
    }

    @Test("Analyze requires POST; others require GET")
    func methods() {
        #expect(APIRoute.analyze(alertmanagerID: "a", fingerprint: "b").method == "POST")
        #expect(APIRoute.analysis(alertmanagerID: "a", fingerprint: "b").method == "GET")
        #expect(APIRoute.alertmanagers.method == "GET")
    }

    @Test("Unknown paths do not match")
    func unknown() {
        #expect(APIRoute.match(["api", "unknown"]) == nil)
        #expect(APIRoute.match(["api", "alertmanagers", "AM", "wrong"]) == nil)
        #expect(APIRoute.match(["a", "b", "c", "d", "e"]) == nil)
    }

    @Test("Analyses collection route")
    func analyses() {
        #expect(APIRoute.match(["api", "analyses"]) == .analyses)
        #expect(APIRoute.analyses.method == "GET")
    }
}

// MARK: - AnalysisManager.parseFileName + APIServer.analysisFiles

@Suite("AnalysisManager.parseFileName")
struct ParseFileNameTests {

    @Test("Parses a well-formed analysis filename")
    func parsesValid() throws {
        let parsed = try #require(AnalysisManager.parseFileName("HighCPU_20260707T174501Z.md"))
        #expect(parsed.alertName == "HighCPU")

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 7
        components.hour = 17
        components.minute = 45
        components.second = 1
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: components)
        #expect(parsed.startsAt == expected)
    }

    @Test("Splits at the last underscore so names with underscores survive")
    func nameWithUnderscore() throws {
        let parsed = try #require(AnalysisManager.parseFileName("High_CPU_20260101T000000Z.md"))
        #expect(parsed.alertName == "High_CPU")
    }

    @Test("Rejects non-.md files")
    func rejectsNonMarkdown() {
        #expect(AnalysisManager.parseFileName("HighCPU_20260707T174501Z.txt") == nil)
    }

    @Test("Rejects names without a valid timestamp")
    func rejectsBadTimestamp() {
        #expect(AnalysisManager.parseFileName("HighCPU_notadate.md") == nil)
        #expect(AnalysisManager.parseFileName("nounderscore.md") == nil)
    }

    @Test("Round-trips with fileName(for:)")
    @MainActor
    func roundTrip() throws {
        // Whole-second start time so the second-precision filename round-trips.
        let start = Date(timeIntervalSince1970: 1_783_600_000)
        let alert = makeAlert(labels: ["alertname": "HighCPU"])
        let named = GettableAlert(
            annotations: alert.annotations, receivers: alert.receivers,
            fingerprint: alert.fingerprint, startsAt: start, updatedAt: start, endsAt: start,
            status: alert.status, labels: alert.labels, generatorURL: alert.generatorURL)

        let fileName = AnalysisManager.shared.fileName(for: named)
        let parsed = try #require(AnalysisManager.parseFileName(fileName))
        #expect(parsed.alertName == "HighCPU")
        #expect(parsed.startsAt == start)
    }
}

@Suite("APIServer.analysisFiles")
struct APIServerAnalysisFilesTests {

    @Test("Filters non-matching names and sorts newest-first, carrying markdown")
    func filtersAndSorts() {
        let entries: [(name: String, path: String, markdown: String?)] = [
            ("HighCPU_20260101T000000Z.md", "/dir/HighCPU_20260101T000000Z.md", "# HighCPU"),
            ("LowMem_20260601T120000Z.md", "/dir/LowMem_20260601T120000Z.md", "# LowMem"),
            ("not-an-analysis.txt", "/dir/not-an-analysis.txt", "ignored"),
            ("README.md", "/dir/README.md", "readme"),
        ]
        let result = APIServer.analysisFiles(from: entries)
        #expect(result.count == 2)
        // Newest first.
        #expect(result.first?.alertName == "LowMem")
        #expect(result.first?.filePath == "/dir/LowMem_20260601T120000Z.md")
        #expect(result.first?.markdown == "# LowMem")
        #expect(result.last?.alertName == "HighCPU")
        #expect(result.last?.markdown == "# HighCPU")
    }
}

// MARK: - APIActions.build

@Suite("APIActions.build")
struct APIActionsBuildTests {

    @Test("Standard backend: source sanitized, runbook and silence passed through")
    func standard() {
        let alert = makeAlert(
            annotations: ["runbook_url": "http://runbook.example.com"],
            generatorURL: "http://prometheus:9090/graph")
        let actions = APIActions.build(
            for: alert, alertmanager: makeAlertmanager(), silence: "http://silence")

        #expect(actions.source == "http://prometheus:9090/graph")
        #expect(actions.runbook == "http://runbook.example.com")
        #expect(actions.silence == "http://silence")
        #expect(actions.dashboard == nil)
        #expect(actions.panel == nil)
    }

    @Test("Absent generatorURL and runbook produce nil actions")
    func absent() {
        let actions = APIActions.build(
            for: makeAlert(), alertmanager: makeAlertmanager(), silence: nil)
        #expect(actions.source == nil)
        #expect(actions.runbook == nil)
        #expect(actions.silence == nil)
    }

    @Test("Grafana backend with dashboard and panel annotations")
    func grafanaDashboardAndPanel() {
        let alert = makeAlert(annotations: ["__dashboardUid__": "abc", "__panelId__": "7"])
        let am = makeAlertmanager(url: "http://grafana.example.com", isGrafana: true)
        let actions = APIActions.build(for: alert, alertmanager: am, silence: nil)

        #expect(actions.dashboard == "http://grafana.example.com/d/abc")
        #expect(actions.panel == "http://grafana.example.com/d/abc?viewPanel=7")
    }

    @Test("Grafana backend with only a dashboard UID omits the panel action")
    func grafanaDashboardOnly() {
        let alert = makeAlert(annotations: ["__dashboardUid__": "abc"])
        let am = makeAlertmanager(url: "http://grafana.example.com", isGrafana: true)
        let actions = APIActions.build(for: alert, alertmanager: am, silence: nil)

        #expect(actions.dashboard == "http://grafana.example.com/d/abc")
        #expect(actions.panel == nil)
    }

    @Test("Nil action keys are omitted from the JSON")
    func omitsNilKeys() throws {
        let actions = APIActions(
            source: "http://s", silence: nil, runbook: nil, dashboard: nil, panel: nil)
        let encoder = JSONEncoder()
        let data = try encoder.encode(actions)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?.keys.contains("source") == true)
        #expect(object?.keys.contains("silence") == false)
        #expect(object?.keys.contains("dashboard") == false)
    }
}

// MARK: - Analyze status logic + auth label

@Suite("APIServer.analyzeStatus")
struct APIServerAnalyzeStatusTests {

    @Test("Unresolved alert yields 404")
    func notFound() {
        #expect(
            APIServer.analyzeStatus(alertResolved: false, commandConfigured: true, running: false)
                == 404)
    }

    @Test("Missing command yields 422")
    func notConfigured() {
        #expect(
            APIServer.analyzeStatus(alertResolved: true, commandConfigured: false, running: false)
                == 422)
    }

    @Test("Already running yields 409")
    func alreadyRunning() {
        #expect(
            APIServer.analyzeStatus(alertResolved: true, commandConfigured: true, running: true)
                == 409)
    }

    @Test("Ready to start yields 202")
    func start() {
        #expect(
            APIServer.analyzeStatus(alertResolved: true, commandConfigured: true, running: false)
                == 202)
    }
}

@Suite("APIServer.authTypeLabel")
struct APIServerAuthLabelTests {

    @Test("Maps auth types to non-secret labels")
    func labels() {
        #expect(APIServer.authTypeLabel(.none) == "none")
        #expect(APIServer.authTypeLabel(.basicAuth(username: "u", password: "p")) == "basic")
        #expect(APIServer.authTypeLabel(.tokenAuth(tokenSource: .direct(token: "t"))) == "token")
    }
}

// MARK: - APIAnalysisResponse encoding

@Suite("APIAnalysisResponse encoding")
struct APIAnalysisResponseTests {

    @Test("markdown is emitted as explicit null when absent")
    func explicitNull() throws {
        let response = APIAnalysisResponse(
            available: true, exists: false, running: false, markdown: nil,
            filePath: "/dir/HighCPU_20260707T174501Z.md")
        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Key present, value is NSNull.
        #expect(object?.keys.contains("markdown") == true)
        #expect(object?["markdown"] is NSNull)
        // filePath is always present and absolute.
        #expect(object?["filePath"] as? String == "/dir/HighCPU_20260707T174501Z.md")
    }
}

// MARK: - Loopback integration

@Suite("APIServer loopback integration")
struct APIServerIntegrationTests {

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([Alertmanager.self, Filter.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Serves /healthz and /api/alertmanagers over an ephemeral loopback port")
    @MainActor
    func servesEndpoints() async throws {
        let container = try makeInMemoryContainer()
        let server = APIServer(port: 0)
        server.configure(with: container)
        server.start()
        defer { server.stop() }

        // Wait for the listener to bind and report its OS-assigned port.
        var port: UInt16?
        for _ in 0..<50 {
            if let resolved = server.resolvedPort {
                port = resolved
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let boundPort = try #require(port, "listener did not become ready")

        // /healthz
        let healthURL = try #require(URL(string: "http://127.0.0.1:\(boundPort)/healthz"))
        let (healthData, healthResponse) = try await URLSession.shared.data(from: healthURL)
        #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
        let health = try JSONDecoder().decode(StatusDecode.self, from: healthData)
        #expect(health.status == "ok")

        // /api/alertmanagers (empty store → empty array)
        let amURL = try #require(URL(string: "http://127.0.0.1:\(boundPort)/api/alertmanagers"))
        let (amData, amResponse) = try await URLSession.shared.data(from: amURL)
        #expect((amResponse as? HTTPURLResponse)?.statusCode == 200)
        let summaries = try JSONDecoder().decode([APIAlertmanagerSummaryDecode].self, from: amData)
        #expect(summaries.isEmpty)

        // Unknown route → 404
        let missingURL = try #require(URL(string: "http://127.0.0.1:\(boundPort)/api/nope"))
        let (_, missingResponse) = try await URLSession.shared.data(from: missingURL)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Enriches an alert with curated fields, markdown, actions, and raw payload")
    @MainActor
    func enrichesAlert() async throws {
        let container = try makeInMemoryContainer()
        // Loopback:1 fails fast, so the monitoring fetch triggered by start()
        // errors immediately and leaves the seeded cache untouched.
        let alertmanager = Alertmanager(name: "Prod", url: "http://127.0.0.1:1")
        container.mainContext.insert(alertmanager)
        try container.mainContext.save()

        let alert = makeAlert(
            fingerprint: "abc123",
            labels: ["alertname": "HighCPU", "severity": "critical"],
            annotations: ["runbook_url": "http://runbook.example.com", "summary": "cpu high"],
            generatorURL: "http://prometheus:9090/graph")
        AlertsManager.shared.alertsByAlertmanager[alertmanager.id] = [alert]
        defer { AlertsManager.shared.alertsByAlertmanager[alertmanager.id] = nil }

        let server = APIServer(port: 0)
        server.configure(with: container)
        server.start()
        defer { server.stop() }

        var port: UInt16?
        for _ in 0..<50 {
            if let resolved = server.resolvedPort {
                port = resolved
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let boundPort = try #require(port, "listener did not become ready")

        let url = try #require(
            URL(
                string:
                    "http://127.0.0.1:\(boundPort)/api/alertmanagers/\(alertmanager.id.uuidString)/alerts"
            ))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601  // server encodes dates as ISO-8601
        let alerts = try decoder.decode([EnrichedAlertDecode].self, from: data)

        #expect(alerts.count == 1)
        let first = try #require(alerts.first)
        #expect(first.fingerprint == "abc123")
        #expect(first.alertName == "HighCPU")
        #expect(first.severity == "critical")
        #expect(first.state == "active")
        #expect(first.summary == "cpu high")
        #expect(first.alertmanager.name == "Prod")
        #expect(first.markdown.contains("HighCPU"))
        // Credentials must never leak into the API markdown.
        #expect(!first.markdown.contains("Credentials"))
        #expect(first.actions.source == "http://prometheus:9090/graph")
        #expect(first.actions.runbook == "http://runbook.example.com")
        #expect(first.raw.fingerprint == "abc123")
        // A freshly-seeded alert has no analysis run in flight. (`available`
        // reflects the host's real `analyzeCommand` setting, so it isn't
        // asserted here.)
        #expect(first.analysis.running == false)
    }
}

// Local decode-only mirrors (the API DTOs are encode-only).
private struct StatusDecode: Decodable {
    let status: String
}

private struct APIAlertmanagerSummaryDecode: Decodable {
    let id: UUID
    let name: String
}

private struct EnrichedAlertDecode: Decodable {
    struct AMRef: Decodable {
        let id: UUID
        let name: String
    }
    struct Actions: Decodable {
        let source: String?
        let runbook: String?
    }
    struct Analysis: Decodable {
        let available: Bool
        let exists: Bool
        let running: Bool
    }
    let fingerprint: String
    let alertName: String
    let severity: String
    let state: String
    let summary: String?
    let alertmanager: AMRef
    let markdown: String
    let actions: Actions
    let analysis: Analysis
    let raw: GettableAlert
}
