//
//  AlertTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - GettableAlert JSON decode helpers

private let iso8601Decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

private func makeAlertJSON(
    annotations: String = "{}",
    receivers: String = "[]",
    fingerprint: String = "fp1",
    startsAt: String = "2024-01-01T00:00:00Z",
    updatedAt: String = "2024-01-01T00:00:00Z",
    endsAt: String = "2024-01-01T01:00:00Z",
    state: String = "active",
    silencedBy: String = "[]",
    inhibitedBy: String = "[]",
    mutedByField: String? = nil,
    labels: String = "{}"
) -> Data {
    let mutedByClause = mutedByField.map { ",\"mutedBy\":\($0)" } ?? ""
    let json = """
    {
        "annotations": \(annotations),
        "receivers": \(receivers),
        "fingerprint": "\(fingerprint)",
        "startsAt": "\(startsAt)",
        "updatedAt": "\(updatedAt)",
        "endsAt": "\(endsAt)",
        "status": {
            "state": "\(state)",
            "silencedBy": \(silencedBy),
            "inhibitedBy": \(inhibitedBy)\(mutedByClause)
        },
        "labels": \(labels)
    }
    """
    return json.data(using: .utf8)!
}

// MARK: - AlertStatus tests

@Suite("AlertStatus decode")
struct AlertStatusTests {

    @Test("Decodes when mutedBy is present")
    func decodesWithMutedBy() throws {
        let data = makeAlertJSON(mutedByField: "[\"silence-1\"]")
        let alert = try iso8601Decoder.decode(GettableAlert.self, from: data)
        #expect(alert.status.mutedBy == ["silence-1"])
    }

    @Test("Decodes when mutedBy is absent")
    func decodesWithoutMutedBy() throws {
        let data = makeAlertJSON(mutedByField: nil)
        let alert = try iso8601Decoder.decode(GettableAlert.self, from: data)
        #expect(alert.status.mutedBy == nil)
    }

    @Test("Decodes all three alert states")
    func decodesAlertStates() throws {
        for (raw, expected) in [("active", AlertState.active), ("suppressed", .suppressed), ("unprocessed", .unprocessed)] {
            let data = makeAlertJSON(state: raw)
            let alert = try iso8601Decoder.decode(GettableAlert.self, from: data)
            #expect(alert.status.state == expected)
        }
    }
}

// MARK: - GettableAlert computed properties

@Suite("GettableAlert computed properties")
struct GettableAlertComputedTests {

    private func makeAlert(
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        silencedBy: [String] = [],
        inhibitedBy: [String] = [],
        fingerprint: String = "fp"
    ) -> GettableAlert {
        GettableAlert(
            annotations: annotations,
            receivers: [],
            fingerprint: fingerprint,
            startsAt: Date(),
            updatedAt: Date(),
            endsAt: Date(),
            status: AlertStatus(state: .active, silencedBy: silencedBy, inhibitedBy: inhibitedBy),
            labels: labels,
            generatorURL: nil
        )
    }

    // MARK: alertName

    @Test("alertName returns label value")
    func alertNameFromLabel() {
        let a = makeAlert(labels: ["alertname": "HighCPU"])
        #expect(a.alertName == "HighCPU")
    }

    @Test("alertName falls back to sentinel when label absent")
    func alertNameFallback() {
        let a = makeAlert(labels: [:])
        #expect(a.alertName == "UnknownAlert")
    }

    // MARK: severity

    @Test("severity returns label value")
    func severityFromLabel() {
        let a = makeAlert(labels: ["severity": "critical"])
        #expect(a.severity == "critical")
    }

    @Test("severity falls back to sentinel when label absent")
    func severityFallback() {
        let a = makeAlert(labels: [:])
        #expect(a.severity == "unknown")
    }

    // MARK: isSilenced / isInhibited

    @Test("isSilenced is true when silencedBy is non-empty")
    func isSilencedTrue() {
        let a = makeAlert(silencedBy: ["s1"])
        #expect(a.isSilenced == true)
    }

    @Test("isSilenced is false when silencedBy is empty")
    func isSilencedFalse() {
        let a = makeAlert(silencedBy: [])
        #expect(a.isSilenced == false)
    }

    @Test("isInhibited is true when inhibitedBy is non-empty")
    func isInhibitedTrue() {
        let a = makeAlert(inhibitedBy: ["i1"])
        #expect(a.isInhibited == true)
    }

    @Test("isInhibited is false when inhibitedBy is empty")
    func isInhibitedFalse() {
        let a = makeAlert(inhibitedBy: [])
        #expect(a.isInhibited == false)
    }

    // MARK: subtitle priority chain

    @Test("subtitle prefers summary")
    func subtitlePrefersSummary() {
        let a = makeAlert(annotations: ["summary": "S", "description": "D", "message": "M"])
        #expect(a.subtitle == "S")
    }

    @Test("subtitle falls back to description when summary absent")
    func subtitleFallsToDescription() {
        let a = makeAlert(annotations: ["description": "D", "message": "M"])
        #expect(a.subtitle == "D")
    }

    @Test("subtitle falls back to message when summary and description absent")
    func subtitleFallsToMessage() {
        let a = makeAlert(annotations: ["message": "M"])
        #expect(a.subtitle == "M")
    }

    @Test("subtitle is nil when no relevant annotations")
    func subtitleNil() {
        let a = makeAlert(annotations: [:])
        #expect(a.subtitle == nil)
    }

    // MARK: runbookURL

    @Test("runbookURL returns annotation value")
    func runbookURL() {
        let a = makeAlert(annotations: ["runbook_url": "https://example.com/runbook"])
        #expect(a.runbookURL == "https://example.com/runbook")
    }

    @Test("runbookURL is nil when annotation absent")
    func runbookURLNil() {
        let a = makeAlert(annotations: [:])
        #expect(a.runbookURL == nil)
    }

    // MARK: id == fingerprint

    @Test("id equals fingerprint")
    func idEqualsFingerprint() {
        let a = makeAlert(fingerprint: "abc123")
        #expect(a.id == "abc123")
    }
}
