//
//  AlertAggregatorTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlert(
    fingerprint: String,
    state: AlertState = .active,
    labels: [String: String] = [:]
) -> GettableAlert {
    GettableAlert(
        annotations: [:],
        receivers: [],
        fingerprint: fingerprint,
        startsAt: Date(),
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: state, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: nil
    )
}

// MARK: - AlertAggregator tests

@Suite("AlertAggregator")
struct AlertAggregatorTests {

    @Test("Returns only alerts from alertmanagers referenced by the filter")
    func respectsSelectedAlertmanagerIDs() {
        let id1 = UUID()
        let id2 = UUID()
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [id1],
            states: []
        )
        let cache: [UUID: [GettableAlert]] = [
            id1: [makeAlert(fingerprint: "a1"), makeAlert(fingerprint: "a2")],
            id2: [makeAlert(fingerprint: "b1")],
        ]

        let result = AlertAggregator.alerts(for: filter, from: cache)
        let fps = Set(result.map(\.fingerprint))
        #expect(fps == ["a1", "a2"])
        #expect(!fps.contains("b1"))
    }

    @Test("Deduplicates alerts with the same fingerprint across alertmanagers")
    func deduplicatesByFingerprint() {
        let id1 = UUID()
        let id2 = UUID()
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [id1, id2],
            states: []
        )
        let shared = makeAlert(fingerprint: "shared")
        let cache: [UUID: [GettableAlert]] = [
            id1: [shared],
            id2: [shared, makeAlert(fingerprint: "unique")],
        ]

        let result = AlertAggregator.alerts(for: filter, from: cache)
        let fps = result.map(\.fingerprint)
        let sharedCount = fps.filter { $0 == "shared" }.count
        #expect(sharedCount == 1)
        #expect(fps.contains("unique"))
    }

    @Test("Applies filter predicates (state predicate)")
    func appliesFilterPredicates() {
        let id = UUID()
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [id],
            states: [.active]
        )
        let cache: [UUID: [GettableAlert]] = [
            id: [
                makeAlert(fingerprint: "active", state: .active),
                makeAlert(fingerprint: "suppressed", state: .suppressed),
            ]
        ]

        let result = AlertAggregator.alerts(for: filter, from: cache)
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "active")
    }

    @Test("Returns empty array when filter references an unknown alertmanager ID")
    func unknownAlertmanagerIDReturnsEmpty() {
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [UUID()],
            states: []
        )
        let result = AlertAggregator.alerts(for: filter, from: [:])
        #expect(result.isEmpty)
    }

    @Test("Returns empty array when cache entry for the alertmanager is empty")
    func emptyCache() {
        let id = UUID()
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [id], states: [])
        let result = AlertAggregator.alerts(for: filter, from: [id: []])
        #expect(result.isEmpty)
    }
}
