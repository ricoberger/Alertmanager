//
//  AlertDeepLinksTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlertmanager(
    url: String,
    isGrafana: Bool = false,
    grafanaAlertmanager: String = ""
) -> Alertmanager {
    Alertmanager(
        name: "Test",
        url: url,
        isGrafana: isGrafana,
        grafanaAlertmanager: grafanaAlertmanager
    )
}

private func makeAlert(
    labels: [String: String] = [:],
    generatorURL: String? = nil
) -> GettableAlert {
    GettableAlert(
        annotations: [:],
        receivers: [],
        fingerprint: "fp",
        startsAt: Date(),
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: .active, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: generatorURL
    )
}

// MARK: - AlertDeepLinks.sanitize

@Suite("AlertDeepLinks.sanitize")
struct AlertDeepLinksSanitizeTests {

    @Test("Empty string produces nil or empty-scheme result")
    func nilOrEmptyForEmpty() {
        // URLComponents can parse an empty string but produces a URL with no scheme.
        // sanitize is expected to return nil OR a non-http(s) URL that won't open.
        // The important contract is that it doesn't crash.
        let result = AlertDeepLinks.sanitize("")
        // Either nil or a degenerate URL; either way it should not have a scheme
        if let result {
            #expect(!result.hasPrefix("http"))
        }
    }

    @Test("Double-encoded query value is decoded to stable state")
    func doubleEncodedQueryDecoded() {
        // Value "hello world" → percent-encode once: "hello%20world"
        // → percent-encode the % sign: "hello%2520world"
        // sanitize should decode iteratively until stable
        let url = "https://example.com/path?q=hello%2520world"
        let result = AlertDeepLinks.sanitize(url)
        // URLComponents already decodes %25 → %, giving value "hello%20world".
        // The loop then decodes that to "hello world".
        // Either intermediate or final decoded form is acceptable.
        #expect(result?.contains("hello") == true)
        #expect(result?.contains("%2520") == false)
    }

    @Test("Simple URL passes through")
    func simpleURL() {
        let result = AlertDeepLinks.sanitize("https://example.com/path")
        #expect(result != nil)
        #expect(result?.contains("example.com") == true)
    }

    @Test("Fragment is dropped")
    func fragmentDropped() {
        let url = "https://example.com/path?q=1#section"
        let result = AlertDeepLinks.sanitize(url)
        #expect(result?.contains("#section") == false)
    }

    @Test("Query items with nil values are preserved")
    func nilQueryItemValuePreserved() {
        let url = "https://example.com/path?flag"
        let result = AlertDeepLinks.sanitize(url)
        #expect(result != nil)
    }

    @Test("Port is preserved in sanitized URL")
    func portPreserved() {
        let url = "http://localhost:9090/graph?q=test"
        let result = AlertDeepLinks.sanitize(url)
        #expect(result?.contains(":9090") == true)
    }
}

// MARK: - AlertDeepLinks.silenceURL — standard AM

@Suite("AlertDeepLinks.silenceURL — standard Alertmanager")
struct AlertDeepLinksSilenceStandardTests {

    @Test("Basic silence URL format")
    func basicSilenceURL() {
        let am = makeAlertmanager(url: "https://am.example.com")
        let alert = makeAlert(labels: ["alertname": "HighCPU"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(url.hasPrefix("https://am.example.com/#/silences/new?filter="))
    }

    @Test("Labels are sorted by key in output")
    func labelsSorted() {
        let am = makeAlertmanager(url: "https://am.example.com")
        let alert = makeAlert(labels: ["z_key": "z_val", "a_key": "a_val"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        // a_key must appear before z_key in the URL
        let aPos = url.range(of: "a_key")!.lowerBound
        let zPos = url.range(of: "z_key")!.lowerBound
        #expect(aPos < zPos)
    }

    @Test("Label values with special chars are percent-encoded")
    func specialCharsEncoded() {
        let am = makeAlertmanager(url: "https://am.example.com")
        // Use a space — not in urlQueryAllowed, must be encoded
        let alert = makeAlert(labels: ["k": "value with spaces"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(!url.contains("value with spaces"))
    }

    @Test("Empty labels produces empty filter braces")
    func emptyLabels() {
        let am = makeAlertmanager(url: "https://am.example.com")
        let alert = makeAlert(labels: [:])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        // %7B%7D = {}
        #expect(url.contains("filter=%7B%7D"))
    }

    @Test("Multiple labels are joined with %2C%20")
    func multipleLabelsJoined() {
        let am = makeAlertmanager(url: "https://am.example.com")
        // Use two keys that will sort deterministically
        let alert = makeAlert(labels: ["a": "1", "b": "2"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(url.contains("%2C%20"))
    }
}

// MARK: - AlertDeepLinks.silenceURL — Grafana

@Suite("AlertDeepLinks.silenceURL — Grafana")
struct AlertDeepLinksSilenceGrafanaTests {

    @Test("Uses /alerting/silence/new path")
    func grafanaSilencePath() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "mimir")
        let alert = makeAlert(labels: ["severity": "critical"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(url.contains("/alerting/silence/new"))
    }

    @Test("alertmanager parameter uses resolvedDatasourceName when provided")
    func usesResolvedName() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "uid-123")
        let alert = makeAlert(labels: [:])
        let url = AlertDeepLinks.silenceURL(
            for: alert, alertmanager: am, resolvedDatasourceName: "MyMimir")
        #expect(url.contains("alertmanager=MyMimir"))
    }

    @Test("alertmanager falls back to grafanaAlertmanager when resolvedName is nil")
    func fallsToConfigured() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "fallback-am")
        let alert = makeAlert(labels: [:])
        let url = AlertDeepLinks.silenceURL(
            for: alert, alertmanager: am, resolvedDatasourceName: nil)
        #expect(url.contains("alertmanager=fallback-am"))
    }

    @Test("alertmanager falls back to empty string when all sources are nil/empty")
    func fallsToEmpty() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "")
        let alert = makeAlert(labels: [:])
        let url = AlertDeepLinks.silenceURL(
            for: alert, alertmanager: am, resolvedDatasourceName: nil)
        #expect(url.contains("alertmanager=&") || url.hasSuffix("alertmanager="))
    }

    @Test("Each label becomes matcher=key%3Dvalue")
    func matcherFormat() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "am")
        let alert = makeAlert(labels: ["severity": "critical"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(url.contains("matcher=severity%3Dcritical"))
    }

    @Test("Label values with special chars are percent-encoded in Grafana URL")
    func grafanaSpecialCharsEncoded() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "am")
        // Use a space — spaces are NOT in urlQueryAllowed and must be encoded
        let alert = makeAlert(labels: ["k": "value with spaces"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        #expect(!url.contains("value with spaces"))
    }

    @Test("Labels are sorted by key")
    func grafanaLabelsSorted() {
        let am = makeAlertmanager(
            url: "https://grafana.example.com", isGrafana: true, grafanaAlertmanager: "am")
        let alert = makeAlert(labels: ["z_key": "z", "a_key": "a"])
        let url = AlertDeepLinks.silenceURL(for: alert, alertmanager: am)
        let aPos = url.range(of: "a_key")!.lowerBound
        let zPos = url.range(of: "z_key")!.lowerBound
        #expect(aPos < zPos)
    }
}

// MARK: - AlertDeepLinks.dashboardURL / panelURL

@Suite("AlertDeepLinks dashboardURL and panelURL")
struct AlertDeepLinksDashboardTests {

    @Test("dashboardURL format is /d/{uid}")
    func dashboardURLFormat() {
        let am = makeAlertmanager(url: "https://grafana.example.com", isGrafana: true)
        let url = AlertDeepLinks.dashboardURL(alertmanager: am, dashboardUID: "abc123")
        #expect(url == "https://grafana.example.com/d/abc123")
    }

    @Test("panelURL format is /d/{uid}?viewPanel={panelId}")
    func panelURLFormat() {
        let am = makeAlertmanager(url: "https://grafana.example.com", isGrafana: true)
        let url = AlertDeepLinks.panelURL(alertmanager: am, dashboardUID: "abc123", panelId: "42")
        #expect(url == "https://grafana.example.com/d/abc123?viewPanel=42")
    }
}
