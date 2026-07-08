//
//  ImportExportManagerTests.swift
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

private func makeAlertmanager(
    name: String,
    url: String,
    authType: AuthenticationType = .none
) -> Alertmanager {
    Alertmanager(name: name, url: url, authType: authType)
}

/// Snapshot of every `SettingsManager` preference.
///
/// `ImportExportManager.importData` writes imported settings straight into
/// `SettingsManager.shared` — i.e. the real `UserDefaults` of the test host
/// — and `exportData` embeds the current settings into every export. Tests
/// that exercise import must therefore capture the settings up front and
/// restore them on exit, or they clobber the developer's actual
/// configuration (refresh interval, menu-bar filter selection, …).
///
/// Usage: `let snapshot = SettingsSnapshot(); defer { snapshot.restore() }`.
@MainActor
private struct SettingsSnapshot {
    private let refreshInterval: TimeInterval
    private let menuBarEnabled: Bool
    private let menuBarFilterID: String?
    private let labelBadgeConfigs: [LabelBadgeConfig]
    private let showAlertmanagerName: Bool
    private let analyzeCommand: String

    init() {
        let settings = SettingsManager.shared
        refreshInterval = settings.refreshInterval
        menuBarEnabled = settings.menuBarEnabled
        menuBarFilterID = settings.menuBarFilterID
        labelBadgeConfigs = settings.labelBadgeConfigs
        showAlertmanagerName = settings.showAlertmanagerName
        analyzeCommand = settings.analyzeCommand
    }

    func restore() {
        let settings = SettingsManager.shared
        settings.refreshInterval = refreshInterval
        settings.menuBarEnabled = menuBarEnabled
        settings.menuBarFilterID = menuBarFilterID
        settings.labelBadgeConfigs = labelBadgeConfigs
        settings.showAlertmanagerName = showAlertmanagerName
        settings.analyzeCommand = analyzeCommand
    }
}

// MARK: - ExportAuthType decode

@Suite("ExportAuthType decode")
struct ExportAuthTypeDecodeTests {

    @Test("Decodes 'none' type")
    func decodesNone() throws {
        let json = #"{"type":"none"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .none)
    }

    @Test("Decodes 'basicAuth' type")
    func decodesBasicAuth() throws {
        let json = #"{"type":"basicAuth","username":"alice","password":"secret"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .basicAuth(username: "alice", password: "secret"))
    }

    @Test("Decodes 'token' type")
    func decodesToken() throws {
        let json = #"{"type":"token","token":"tok123"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .token(token: "tok123"))
    }

    @Test("Decodes 'tokenFromFile' type")
    func decodesTokenFromFile() throws {
        let json = #"{"type":"tokenFromFile","path":"/var/run/token"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .tokenFromFile(path: "/var/run/token"))
    }

    @Test("Decodes 'tokenFromCommand' type")
    func decodesTokenFromCommand() throws {
        let json = #"{"type":"tokenFromCommand","command":"get-token"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .tokenFromCommand(command: "get-token"))
    }

    @Test("Unknown type discriminator falls back to .none")
    func unknownTypeFallsToNone() throws {
        let json = #"{"type":"oauth2","somefield":"val"}"#.data(using: .utf8)!
        let v = try JSONDecoder().decode(ExportAuthType.self, from: json)
        #expect(v == .none)
    }
}

// MARK: - Export/import round-trips

@Suite("ImportExportManager round-trip")
struct ImportExportRoundTripTests {

    @Test("Round-trip: export then import produces same alertmanager count")
    @MainActor
    func roundTripAlertmanagerCount() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am1 = makeAlertmanager(name: "Prod", url: "https://prod.example.com")
        let am2 = makeAlertmanager(name: "Staging", url: "https://staging.example.com")
        context.insert(am1)
        context.insert(am2)
        try context.save()

        let data = try #require(ImportExportManager.exportData(alertmanagers: [am1, am2], filters: []))

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        let result = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        #expect(result.alertmanagers == 2)

        let imported = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        #expect(imported.count == 2)
    }

    @Test("Round-trip: filter references alertmanager by name")
    @MainActor
    func filterReferenceByName() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = makeAlertmanager(name: "Prod", url: "https://prod.example.com")
        context.insert(am)
        try context.save()

        let filter = Filter(
            name: "Critical",
            selectedAlertmanagerIDs: [am.id],
            states: [.active]
        )
        context.insert(filter)
        try context.save()

        let data = try #require(ImportExportManager.exportData(alertmanagers: [am], filters: [filter]))

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        let result = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        #expect(result.filters == 1)

        let importedAMs = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        let importedFilters = try freshContext.fetch(FetchDescriptor<Filter>())
        let importedAM = try #require(importedAMs.first)
        let importedFilter = try #require(importedFilters.first)

        // The filter should point to the newly imported alertmanager's id
        #expect(importedFilter.selectedAlertmanagerIDs.contains(importedAM.id))
    }

    @Test("Importing the same file twice does not duplicate alertmanagers")
    @MainActor
    func noDuplicatesOnSecondImport() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = makeAlertmanager(name: "Prod", url: "https://prod.example.com")
        context.insert(am)
        try context.save()

        let data = try #require(ImportExportManager.exportData(alertmanagers: [am], filters: []))

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        // First import
        let r1 = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )
        #expect(r1.alertmanagers == 1)

        let afterFirst = try freshContext.fetch(FetchDescriptor<Alertmanager>())

        // Second import — existing alertmanagers list includes what we just imported
        let r2 = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: afterFirst,
            existingFilters: []
        )
        #expect(r2.alertmanagers == 0)

        let afterSecond = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        #expect(afterSecond.count == 1)
    }

    @Test("Importing the same file twice does not duplicate filters")
    @MainActor
    func noFilterDuplicatesOnSecondImport() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = makeAlertmanager(name: "Prod", url: "https://prod.example.com")
        context.insert(am)
        let filter = Filter(
            name: "Critical",
            selectedAlertmanagerIDs: [am.id],
            states: [.active]
        )
        context.insert(filter)
        try context.save()

        let data = try #require(
            ImportExportManager.exportData(alertmanagers: [am], filters: [filter]))

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        // First import into an empty store inserts the filter.
        let r1 = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )
        #expect(r1.filters == 1)

        let afterFirstAMs = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        let afterFirstFilters = try freshContext.fetch(FetchDescriptor<Filter>())

        // Second import — the same-named filter must be skipped.
        let r2 = try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: afterFirstAMs,
            existingFilters: afterFirstFilters
        )
        #expect(r2.filters == 0)

        let afterSecond = try freshContext.fetch(FetchDescriptor<Filter>())
        #expect(afterSecond.count == 1)
    }

    @Test("Filter referencing unknown alertmanager name ends up with empty selectedAlertmanagerIDs")
    @MainActor
    func unknownAlertmanagerNameDropped() throws {
        // Build an export that references an alertmanager name not present in the import target
        let exportJSON = """
        {
            "alertmanagers": [],
            "filters": [
                {
                    "name": "OrphanFilter",
                    "alertmanagerNames": ["NonExistent"],
                    "states": ["active"],
                    "receivers": [],
                    "labelMatchers": []
                }
            ],
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        let result = try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )
        #expect(result.filters == 1)

        let imported = try freshContext.fetch(FetchDescriptor<Filter>())
        #expect(imported.first?.selectedAlertmanagerIDs.isEmpty == true)
    }

    @Test("Unknown AlertState raw values are dropped")
    @MainActor
    func unknownAlertStateDropped() throws {
        let exportJSON = """
        {
            "alertmanagers": [],
            "filters": [
                {
                    "name": "TestFilter",
                    "alertmanagerNames": [],
                    "states": ["active", "bogusState"],
                    "receivers": [],
                    "labelMatchers": []
                }
            ],
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        let imported = try freshContext.fetch(FetchDescriptor<Filter>())
        // Only the valid "active" state should survive
        #expect(imported.first?.states == [.active])
    }

    @Test("Unknown LabelMatcherOperator raw value drops the whole matcher")
    @MainActor
    func unknownOperatorDropped() throws {
        let exportJSON = """
        {
            "alertmanagers": [],
            "filters": [
                {
                    "name": "TestFilter",
                    "alertmanagerNames": [],
                    "states": [],
                    "receivers": [],
                    "labelMatchers": [
                        {"key": "severity", "op": "=", "value": "critical"},
                        {"key": "namespace", "op": "??", "value": "prod"}
                    ]
                }
            ],
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        let imported = try freshContext.fetch(FetchDescriptor<Filter>())
        // Only the valid matcher with "=" should survive
        #expect(imported.first?.labelMatchers.count == 1)
        #expect(imported.first?.labelMatchers.first?.key == "severity")
    }

    @Test("Defaults: sortOrder=0 and notificationsEnabled=false when absent")
    @MainActor
    func defaultsWhenAbsent() throws {
        let exportJSON = """
        {
            "alertmanagers": [
                {"name": "A", "url": "http://a.example.com", "isGrafana": false, "grafanaAlertmanager": "", "authType": {"type": "none"}}
            ],
            "filters": [
                {"name": "F", "alertmanagerNames": [], "states": [], "receivers": [], "labelMatchers": []}
            ],
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        let ams = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        #expect(ams.first?.sortOrder == 0)

        let filters = try freshContext.fetch(FetchDescriptor<Filter>())
        #expect(filters.first?.sortOrder == 0)
        #expect(filters.first?.notificationsEnabled == false)
    }

    @Test("AuthType round-trip: basicAuth preserved through export→import")
    @MainActor
    func authTypeBasicAuthRoundTrip() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let am = makeAlertmanager(
            name: "Secure",
            url: "https://secure.example.com",
            authType: .basicAuth(username: "user", password: "pass")
        )
        context.insert(am)
        try context.save()

        let data = try #require(ImportExportManager.exportData(alertmanagers: [am], filters: []))

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        try ImportExportManager.importData(
            from: data,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )

        let imported = try freshContext.fetch(FetchDescriptor<Alertmanager>())
        #expect(imported.first?.authType == .basicAuth(username: "user", password: "pass"))
    }

    @Test("settingsRestored is true when settings block is present")
    @MainActor
    func settingsRestoredFlag() throws {
        let snapshot = SettingsSnapshot()
        defer { snapshot.restore() }

        let exportJSON = """
        {
            "alertmanagers": [],
            "filters": [],
            "settings": {
                "refreshInterval": 120,
                "menuBarEnabled": true
            },
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        let result = try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )
        #expect(result.settingsRestored == true)
    }

    @Test("settingsRestored is false when settings block is absent")
    @MainActor
    func settingsNotRestoredWhenAbsent() throws {
        let exportJSON = """
        {
            "alertmanagers": [],
            "filters": [],
            "exportDate": "2024-01-01T00:00:00Z",
            "version": "1.0"
        }
        """.data(using: .utf8)!

        let freshContainer = try makeInMemoryContainer()
        let freshContext = ModelContext(freshContainer)

        let result = try ImportExportManager.importData(
            from: exportJSON,
            modelContext: freshContext,
            existingAlertmanagers: [],
            existingFilters: []
        )
        #expect(result.settingsRestored == false)
    }
}
