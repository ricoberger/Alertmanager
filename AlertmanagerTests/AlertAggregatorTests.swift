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
    labels: [String: String] = [:],
    startsAt: Date = Date()
) -> GettableAlert {
    GettableAlert(
        annotations: [:],
        receivers: [],
        fingerprint: fingerprint,
        startsAt: startsAt,
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: state, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: nil
    )
}

private func makeAlertmanager(name: String) -> Alertmanager {
    Alertmanager(name: name, url: "https://\(name).example.com")
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

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [id1, id2]
        )
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

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [id1, id2]
        )
        let fps = result.map(\.fingerprint)
        let sharedCount = fps.filter { $0 == "shared" }.count
        #expect(sharedCount == 1)
        #expect(fps.contains("unique"))
    }

    @Test("Dedup precedence follows the sidebar order, not the filter's ID order")
    func dedupFollowsSidebarOrder() {
        let id1 = UUID()
        let id2 = UUID()
        // Filter selection lists id2 first; sidebar order has id1 first.
        // The id1 copy of the shared alert should win.
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [id2, id1],
            states: []
        )
        let fromAM1 = makeAlert(fingerprint: "shared", labels: ["source": "am1"])
        let fromAM2 = makeAlert(fingerprint: "shared", labels: ["source": "am2"])
        let cache: [UUID: [GettableAlert]] = [
            id1: [fromAM1],
            id2: [fromAM2],
        ]

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [id1, id2]
        )
        #expect(result.count == 1)
        #expect(result.first?.labels["source"] == "am1")
    }

    @Test("Ignores ordered IDs that are not in the filter's selection")
    func ignoresUnselectedOrderedIDs() {
        let selected = UUID()
        let unselected = UUID()
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [selected],
            states: []
        )
        let cache: [UUID: [GettableAlert]] = [
            selected: [makeAlert(fingerprint: "in")],
            unselected: [makeAlert(fingerprint: "out")],
        ]

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [unselected, selected]
        )
        let fps = result.map(\.fingerprint)
        #expect(fps == ["in"])
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

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [id]
        )
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "active")
    }

    @Test("Empty selection means all alertmanagers")
    func emptySelectionMeansAllAlertmanagers() {
        let id1 = UUID()
        let id2 = UUID()
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [],
            states: []
        )
        let cache: [UUID: [GettableAlert]] = [
            id1: [makeAlert(fingerprint: "a1")],
            id2: [makeAlert(fingerprint: "b1")],
        ]

        let result = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [id1, id2]
        )
        let fps = Set(result.map(\.fingerprint))
        #expect(fps == ["a1", "b1"])
    }

    @Test("Returns empty array when filter references an unknown alertmanager ID")
    func unknownAlertmanagerIDReturnsEmpty() {
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [UUID()],
            states: []
        )
        let result = AlertAggregator.alerts(
            for: filter,
            from: [:],
            orderedAlertmanagerIDs: []
        )
        #expect(result.isEmpty)
    }

    @Test("Returns empty array when cache entry for the alertmanager is empty")
    func emptyCache() {
        let id = UUID()
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [id], states: [])
        let result = AlertAggregator.alerts(
            for: filter,
            from: [id: []],
            orderedAlertmanagerIDs: [id]
        )
        #expect(result.isEmpty)
    }
}

// MARK: - AlertAggregator.alertsWithSources tests

@Suite("AlertAggregator.alertsWithSources")
struct AlertAggregatorAlertsWithSourcesTests {

    @Test("Pairs each alert with the alertmanager that won dedup")
    func pairsWithDedupWinner() {
        let am1 = makeAlertmanager(name: "am1")
        let am2 = makeAlertmanager(name: "am2")
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [am1.id, am2.id], states: [])
        let cache: [UUID: [GettableAlert]] = [
            am1.id: [makeAlert(fingerprint: "shared")],
            am2.id: [makeAlert(fingerprint: "shared"), makeAlert(fingerprint: "only2")],
        ]

        let result = AlertAggregator.alertsWithSources(
            for: filter,
            from: cache,
            orderedAlertmanagers: [am1, am2]
        )
        #expect(result.count == 2)
        // am1 is first in sidebar order, so its copy of "shared" wins.
        #expect(
            result.first(where: { $0.alert.fingerprint == "shared" })?.alertmanager.id == am1.id)
        #expect(result.first(where: { $0.alert.fingerprint == "only2" })?.alertmanager.id == am2.id)
    }

    @Test("Applies the filter after deduplication, matching alerts(for:)")
    func filterAppliedAfterDedup() {
        // The same fingerprint is suppressed in the dedup winner (am1) but
        // active in am2. Dedup-before-filter keeps the am1 copy and the
        // state predicate then drops it — identical to what
        // alerts(for:from:orderedAlertmanagerIDs:) produces.
        let am1 = makeAlertmanager(name: "am1")
        let am2 = makeAlertmanager(name: "am2")
        let filter = Filter(
            name: "f", selectedAlertmanagerIDs: [am1.id, am2.id], states: [.active])
        let cache: [UUID: [GettableAlert]] = [
            am1.id: [makeAlert(fingerprint: "shared", state: .suppressed)],
            am2.id: [makeAlert(fingerprint: "shared", state: .active)],
        ]

        let result = AlertAggregator.alertsWithSources(
            for: filter,
            from: cache,
            orderedAlertmanagers: [am1, am2]
        )
        #expect(result.isEmpty)

        let plain = AlertAggregator.alerts(
            for: filter,
            from: cache,
            orderedAlertmanagerIDs: [am1.id, am2.id]
        )
        #expect(plain.isEmpty)
    }

    @Test("Sorts results newest-first")
    func sortsNewestFirst() {
        let am = makeAlertmanager(name: "am1")
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [am.id], states: [])
        let cache: [UUID: [GettableAlert]] = [
            am.id: [
                makeAlert(fingerprint: "old", startsAt: Date(timeIntervalSince1970: 1_000)),
                makeAlert(fingerprint: "new", startsAt: Date(timeIntervalSince1970: 2_000)),
            ]
        ]

        let result = AlertAggregator.alertsWithSources(
            for: filter,
            from: cache,
            orderedAlertmanagers: [am]
        )
        #expect(result.map(\.alert.fingerprint) == ["new", "old"])
    }

    @Test("Empty selection means all alertmanagers")
    func emptySelectionMeansAllAlertmanagers() {
        let am1 = makeAlertmanager(name: "am1")
        let am2 = makeAlertmanager(name: "am2")
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [])
        let cache: [UUID: [GettableAlert]] = [
            am1.id: [makeAlert(fingerprint: "a1")],
            am2.id: [makeAlert(fingerprint: "b1")],
        ]

        let result = AlertAggregator.alertsWithSources(
            for: filter,
            from: cache,
            orderedAlertmanagers: [am1, am2]
        )
        #expect(Set(result.map(\.alert.fingerprint)) == ["a1", "b1"])
    }
}

// MARK: - Filter.includesAlertmanager tests

@Suite("Filter.includesAlertmanager")
struct FilterIncludesAlertmanagerTests {

    @Test("Empty selection includes every alertmanager")
    func emptySelectionIncludesAll() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [])
        #expect(filter.includesAlertmanager(withID: UUID()))
    }

    @Test("Non-empty selection includes only listed alertmanagers")
    func nonEmptySelectionIsMembershipTest() {
        let selected = UUID()
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [selected])
        #expect(filter.includesAlertmanager(withID: selected))
        #expect(!filter.includesAlertmanager(withID: UUID()))
    }
}
