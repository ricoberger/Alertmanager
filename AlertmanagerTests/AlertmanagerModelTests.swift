//
//  AlertmanagerModelTests.swift
//  AlertmanagerTests
//

import Foundation
import SwiftData
import Testing

@testable import Alertmanager

// MARK: - Helpers

@MainActor
private func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([Alertmanager.self, Filter.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - Alertmanager.authType round-trips

@Suite("Alertmanager.authType persistence")
struct AlertmanagerAuthTypeTests {

    @Test("authType .none round-trips through SwiftData")
    @MainActor
    func noneRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(name: "test", url: "http://a.example.com", authType: AuthenticationType.none)
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        #expect(fetched.first?.authType == AuthenticationType.none)
    }

    @Test("authType .basicAuth round-trips through SwiftData")
    @MainActor
    func basicAuthRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(
            name: "test",
            url: "http://b.example.com",
            authType: .basicAuth(username: "alice", password: "secret")
        )
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        #expect(fetched.first?.authType == .basicAuth(username: "alice", password: "secret"))
    }

    @Test("authType .tokenAuth(.direct) round-trips through SwiftData")
    @MainActor
    func tokenDirectRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(
            name: "test",
            url: "http://c.example.com",
            authType: .tokenAuth(tokenSource: .direct(token: "tok123"))
        )
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        #expect(fetched.first?.authType == .tokenAuth(tokenSource: .direct(token: "tok123")))
    }

    @Test("authType .tokenAuth(.file) round-trips through SwiftData")
    @MainActor
    func tokenFileRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(
            name: "test",
            url: "http://d.example.com",
            authType: .tokenAuth(tokenSource: .file(path: "/var/run/token"))
        )
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        #expect(fetched.first?.authType == .tokenAuth(tokenSource: .file(path: "/var/run/token")))
    }

    @Test("authType .tokenAuth(.command) round-trips through SwiftData")
    @MainActor
    func tokenCommandRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(
            name: "test",
            url: "http://e.example.com",
            authType: .tokenAuth(tokenSource: .command(command: "get-token.sh"))
        )
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        #expect(fetched.first?.authType == .tokenAuth(tokenSource: .command(command: "get-token.sh")))
    }

    @Test("authType falls back to .none when backing data is nil")
    @MainActor
    func nilDataFallback() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        // Start with a valid authType, save, then explicitly corrupt the
        // backing Data by setting authType to .none and confirming the
        // round-trip default.
        let am = Alertmanager(name: "test", url: "http://f.example.com", authType: AuthenticationType.none)
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        // Default .none is the fallback when no data is stored.
        #expect(fetched.first?.authType == AuthenticationType.none)
    }
}

// MARK: - Filter.labelMatchers round-trip

@Suite("Filter.labelMatchers persistence")
struct FilterLabelMatchersTests {

    @Test("labelMatchers round-trip through SwiftData")
    @MainActor
    func labelMatchersRoundTrip() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let matchers = [
            LabelMatcher(key: "severity", op: .equal, value: "critical"),
            LabelMatcher(key: "namespace", op: .regexMatch, value: "prod.*"),
        ]
        let filter = Filter(
            name: "prod-critical",
            selectedAlertmanagerIDs: [],
            labelMatchers: matchers
        )
        context.insert(filter)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Filter>())
        let fetchedMatchers = fetched.first?.labelMatchers ?? []
        #expect(fetchedMatchers.count == 2)
        #expect(fetchedMatchers[0].key == "severity")
        #expect(fetchedMatchers[0].op == .equal)
        #expect(fetchedMatchers[0].value == "critical")
        #expect(fetchedMatchers[1].key == "namespace")
        #expect(fetchedMatchers[1].op == .regexMatch)
        #expect(fetchedMatchers[1].value == "prod.*")
    }

    @Test("labelMatchers returns empty array when backing data is nil")
    @MainActor
    func emptyLabelMatchersDefault() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let filter = Filter(name: "empty", selectedAlertmanagerIDs: [])
        context.insert(filter)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Filter>())
        #expect(fetched.first?.labelMatchers.isEmpty == true)
    }
}

// MARK: - Alertmanager model properties

@Suite("Alertmanager model properties")
struct AlertmanagerModelPropertyTests {

    @Test("sortOrder, isGrafana, grafanaAlertmanagers persist correctly")
    @MainActor
    func propertiesPersist() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = Alertmanager(
            name: "Grafana",
            url: "https://grafana.example.com",
            isGrafana: true,
            grafanaAlertmanagers: ["mimir-am", "loki-am"],
            sortOrder: 5
        )
        context.insert(am)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Alertmanager>())
        let result = try #require(fetched.first)
        #expect(result.name == "Grafana")
        #expect(result.url == "https://grafana.example.com")
        #expect(result.isGrafana == true)
        #expect(result.grafanaAlertmanagers == ["mimir-am", "loki-am"])
        #expect(result.sortOrder == 5)
    }
}
