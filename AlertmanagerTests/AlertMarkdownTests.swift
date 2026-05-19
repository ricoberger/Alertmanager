//
//  AlertMarkdownTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlertmanager(
    url: String = "https://am.example.com",
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
    annotations: [String: String] = [:],
    receivers: [String] = [],
    generatorURL: String? = nil,
    state: AlertState = .active
) -> GettableAlert {
    GettableAlert(
        annotations: annotations,
        receivers: receivers.map { Receiver(name: $0) },
        fingerprint: "fp",
        startsAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endsAt: Date(timeIntervalSince1970: 1_700_003_600),
        status: AlertStatus(state: state, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: generatorURL
    )
}

// MARK: - AlertMarkdown.build

@Suite("AlertMarkdown.build")
struct AlertMarkdownBuildTests {

    @Test("Includes alert name as top-level heading")
    func alertNameHeading() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "HighCPU", "severity": "warning"]),
            alertmanager: makeAlertmanager()
        )
        #expect(md.hasPrefix("# HighCPU"))
    }

    @Test("Falls back to UnknownAlert when alertname label is missing")
    func missingAlertname() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["severity": "info"]),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("# UnknownAlert"))
    }

    @Test("Renders severity, state, and alertmanager URL")
    func coreMetadata() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "Disk", "severity": "critical"],
                state: .suppressed
            ),
            alertmanager: makeAlertmanager(url: "https://am.example.com")
        )
        #expect(md.contains("**Severity:** critical"))
        #expect(md.contains("**State:** Suppressed"))
        #expect(md.contains("**Alertmanager URL:** https://am.example.com"))
    }

    @Test("Renames URL field to Grafana URL and adds datasource for Grafana backends")
    func grafanaURLAndDatasource() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(
                url: "https://grafana.example.com",
                isGrafana: true,
                grafanaAlertmanager: "mimir-prod"
            )
        )
        #expect(md.contains("**Grafana URL:** https://grafana.example.com"))
        #expect(md.contains("**Grafana Alertmanager Datasource:** mimir-prod"))
        #expect(!md.contains("**Alertmanager URL:**"))
    }

    @Test("Omits datasource line for Grafana backends with no configured datasource")
    func grafanaWithoutDatasource() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(
                url: "https://grafana.example.com",
                isGrafana: true,
                grafanaAlertmanager: ""
            )
        )
        #expect(md.contains("**Grafana URL:** https://grafana.example.com"))
        #expect(!md.contains("**Grafana Alertmanager Datasource:**"))
    }

    @Test("Grafana credentials line uses Grafana-specific label")
    func grafanaCredentialsLabel() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(
                url: "https://grafana.example.com",
                isGrafana: true,
                grafanaAlertmanager: "mimir-prod"
            ),
            authCredentials: "Bearer abc"
        )
        #expect(md.contains("**Grafana Credentials:** Bearer abc"))
        #expect(!md.contains("**Alertmanager Credentials:**"))
    }

    @Test("Standard Alertmanager backends do not get a Datasource line")
    func standardBackendNoDatasource() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(url: "https://am.example.com")
        )
        #expect(md.contains("**Alertmanager URL:** https://am.example.com"))
        #expect(!md.contains("**Grafana URL:**"))
        #expect(!md.contains("**Grafana Alertmanager Datasource:**"))
    }

    @Test("Includes credentials line when supplied")
    func includesCredentials() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(),
            authCredentials: "Basic alice:secret"
        )
        #expect(md.contains("**Alertmanager Credentials:** Basic alice:secret"))
    }

    @Test("Omits credentials line when nil")
    func omitsCredentialsWhenNil() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(),
            authCredentials: nil
        )
        #expect(!md.contains("Credentials:"))
    }

    @Test("Omits credentials line when empty string")
    func omitsCredentialsWhenEmpty() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager(),
            authCredentials: ""
        )
        #expect(!md.contains("Credentials:"))
    }

    @Test("Renders receivers when present")
    func rendersReceivers() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                receivers: ["team-a", "team-b"]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("**Receivers:** team-a, team-b"))
    }

    @Test("Omits receivers section when empty")
    func omitsEmptyReceivers() {
        let md = AlertMarkdown.build(
            for: makeAlert(labels: ["alertname": "X", "severity": "warning"]),
            alertmanager: makeAlertmanager()
        )
        #expect(!md.contains("**Receivers:**"))
    }

    @Test("Renders generator URL as Source")
    func rendersSource() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                generatorURL: "http://prometheus:9090/graph"
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("**Source:** http://prometheus:9090/graph"))
    }

    @Test("Emits Description section from description annotation")
    func descriptionSection() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: ["description": "Memory pressure detected"]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("## Description"))
        #expect(md.contains("Memory pressure detected"))
    }

    @Test("Skips Description section when annotation is whitespace only")
    func skipsWhitespaceDescription() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: ["description": "   \n  "]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(!md.contains("## Description"))
    }

    @Test("Labels are sorted by key")
    func labelsSorted() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: [
                    "alertname": "X",
                    "severity": "warning",
                    "zone": "us-east-1",
                    "app": "api",
                ]
            ),
            alertmanager: makeAlertmanager()
        )
        guard
            let alertnameIdx = md.range(of: "`alertname`")?.lowerBound,
            let appIdx = md.range(of: "`app`")?.lowerBound,
            let severityIdx = md.range(of: "`severity`")?.lowerBound,
            let zoneIdx = md.range(of: "`zone`")?.lowerBound
        else {
            Issue.record("expected all label keys to appear")
            return
        }
        #expect(alertnameIdx < appIdx)
        #expect(appIdx < severityIdx)
        #expect(severityIdx < zoneIdx)
    }

    @Test("description and summary are omitted from the Annotations list")
    func descriptionAndSummaryNotDuplicatedInAnnotations() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: [
                    "description": "the description",
                    "summary": "the summary",
                    "runbook_url": "https://r.example.com",
                ]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("## Annotations"))
        #expect(md.contains("`runbook_url`"))
        // The Annotations section must not contain `description` or
        // `summary` bullets — those are surfaced as a heading above.
        if let range = md.range(of: "## Annotations") {
            let suffix = md[range.lowerBound...]
            #expect(!suffix.contains("`description`"))
            #expect(!suffix.contains("`summary`"))
        }
    }

    @Test("Summary and Description are emitted as separate sections, Summary first")
    func summaryAndDescriptionSections() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: [
                    "summary": "High memory pressure",
                    "description": "Memory above 90% for 5m",
                ]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("## Summary"))
        #expect(md.contains("High memory pressure"))
        #expect(md.contains("## Description"))
        #expect(md.contains("Memory above 90% for 5m"))
        guard
            let summaryIdx = md.range(of: "## Summary")?.lowerBound,
            let descriptionIdx = md.range(of: "## Description")?.lowerBound
        else {
            Issue.record("expected both section headings to be rendered")
            return
        }
        #expect(summaryIdx < descriptionIdx)
    }

    @Test("Summary section is emitted alone when no description is present")
    func summaryWithoutDescription() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: ["summary": "Disk is full"]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("## Summary"))
        #expect(md.contains("Disk is full"))
        #expect(!md.contains("## Description"))
    }

    @Test("Description section is emitted alone when no summary is present")
    func descriptionWithoutSummary() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: ["description": "Detail text"]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(md.contains("## Description"))
        #expect(md.contains("Detail text"))
        #expect(!md.contains("## Summary"))
    }

    @Test("Whitespace-only summary is omitted")
    func whitespaceSummaryOmitted() {
        let md = AlertMarkdown.build(
            for: makeAlert(
                labels: ["alertname": "X", "severity": "warning"],
                annotations: [
                    "summary": "   ",
                    "description": "Detail text",
                ]
            ),
            alertmanager: makeAlertmanager()
        )
        #expect(!md.contains("## Summary"))
        #expect(md.contains("## Description"))
        #expect(md.contains("Detail text"))
    }
}
