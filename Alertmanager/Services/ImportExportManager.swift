//
//  ImportExportManager.swift
//  Alertmanager
//

import Foundation
import SwiftData

/// Persisted user settings included in an export bundle. Optional in
/// the file format so older exports without settings still import.
struct ExportSettings: Codable {
    /// Polling cadence in seconds.
    let refreshInterval: TimeInterval
    /// Whether the `MenuBarExtra` is enabled.
    let menuBarEnabled: Bool
    /// Name (not UUID) of the filter selected for the menu bar, so the
    /// reference survives import even though IDs are regenerated.
    let menuBarFilterName: String?
    /// Ordered label-key → color badge mappings shown in alert rows.
    /// `nil` when absent so older export files import without error.
    let labelBadgeConfigs: [LabelBadgeConfig]?
    /// Whether the alertmanager name prefix is shown in the alert row title.
    /// `nil` when absent so older export files import without error.
    let showAlertmanagerName: Bool?
}

/// Top-level shape of the JSON file produced by `exportData` and
/// consumed by `importData`. Versioned so future format changes can be
/// detected and migrated.
struct ExportData: Codable {
    let alertmanagers: [ExportAlertmanager]
    let filters: [ExportFilter]
    let settings: ExportSettings?
    let exportDate: Date
    let version: String
}

/// Portable representation of an `Alertmanager`. Excludes the SwiftData
/// `id` so importing into a different store doesn't collide.
struct ExportAlertmanager: Codable {
    let name: String
    let url: String
    let isGrafana: Bool
    let grafanaAlertmanagers: [String]
    let authType: ExportAuthType
    let sortOrder: Int?
}

/// Portable, JSON-friendly mirror of `AuthenticationType`.
///
/// Encoded with an explicit `type` discriminator plus per-variant fields
/// rather than relying on Swift's default associated-value encoding —
/// this keeps the on-disk format stable and human-readable.
enum ExportAuthType: Codable, Equatable {
    case none
    case basicAuth(username: String, password: String)
    case token(token: String)
    case tokenFromFile(path: String)
    case tokenFromCommand(command: String)

    /// Discriminator and per-variant payload keys.
    enum CodingKeys: String, CodingKey {
        case type
        case username
        case password
        case token
        case path
        case command
    }

    /// Custom decoder that branches on the `type` discriminator.
    /// Unknown types fall back to `.none` to keep imports resilient.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "none":
            self = .none
        case "basicAuth":
            let username = try container.decode(String.self, forKey: .username)
            let password = try container.decode(String.self, forKey: .password)
            self = .basicAuth(username: username, password: password)
        case "token":
            let token = try container.decode(String.self, forKey: .token)
            self = .token(token: token)
        case "tokenFromFile":
            let path = try container.decode(String.self, forKey: .path)
            self = .tokenFromFile(path: path)
        case "tokenFromCommand":
            let command = try container.decode(String.self, forKey: .command)
            self = .tokenFromCommand(command: command)
        default:
            self = .none
        }
    }

    /// Custom encoder that writes the discriminator plus only the keys
    /// relevant to the active variant.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .basicAuth(let username, let password):
            try container.encode("basicAuth", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        case .token(let token):
            try container.encode("token", forKey: .type)
            try container.encode(token, forKey: .token)
        case .tokenFromFile(let path):
            try container.encode("tokenFromFile", forKey: .type)
            try container.encode(path, forKey: .path)
        case .tokenFromCommand(let command):
            try container.encode("tokenFromCommand", forKey: .type)
            try container.encode(command, forKey: .command)
        }
    }
}

/// Portable, JSON-friendly mirror of `LabelMatcher`. The operator is
/// encoded as its raw string (`=`, `!=`, `=~`, `!~`) for human
/// readability in the export file.
struct ExportLabelMatcher: Codable {
    let key: String
    let op: String
    let value: String
}

/// Portable representation of a `Filter`. Stores alertmanager references
/// by **name** rather than UUID so the export can be applied to any
/// store that has matching alertmanagers, even if their IDs differ.
struct ExportFilter: Codable {
    let name: String
    let alertmanagerNames: [String]  // Names instead of UUIDs for portability across stores.
    let states: [String]
    let receivers: [String]
    let labelMatchers: [ExportLabelMatcher]
    let sortOrder: Int?
    let notificationsEnabled: Bool?
}

/// Stateless helper that serializes the SwiftData store to a versioned
/// JSON document and restores it on import.
///
/// Conventions:
/// - **Format version**: `"1.0"`.
/// - **Dates**: ISO-8601.
/// - **JSON style**: pretty-printed, sorted keys (stable diffs).
/// - **References**: filters reference alertmanagers by name, not UUID,
///   so an export can be re-imported into a different store.
class ImportExportManager {
    /// Builds a JSON `Data` blob containing every alertmanager, filter,
    /// and the current `SettingsManager` settings.
    ///
    /// Returns `nil` if encoding fails (which would indicate a
    /// programming error rather than user input — there's nothing
    /// recoverable to surface in the UI).
    static func exportData(alertmanagers: [Alertmanager], filters: [Filter]) -> Data? {
        let exportAlertmanagers = alertmanagers.map { alertmanager in
            ExportAlertmanager(
                name: alertmanager.name,
                url: alertmanager.url,
                isGrafana: alertmanager.isGrafana,
                grafanaAlertmanagers: alertmanager.grafanaAlertmanagers,
                authType: convertAuthType(alertmanager.authType),
                sortOrder: alertmanager.sortOrder
            )
        }

        let exportFilters = filters.map { filter in
            // Map alertmanager IDs → names so the reference survives
            // import into a store with different IDs.
            let alertmanagerNames = filter.selectedAlertmanagerIDs.compactMap { id in
                alertmanagers.first(where: { $0.id == id })?.name
            }

            return ExportFilter(
                name: filter.name,
                alertmanagerNames: alertmanagerNames,
                states: filter.states.map(\.rawValue),
                receivers: filter.receivers,
                labelMatchers: filter.labelMatchers.map { matcher in
                    ExportLabelMatcher(
                        key: matcher.key,
                        op: matcher.op.rawValue,
                        value: matcher.value
                    )
                },
                sortOrder: filter.sortOrder,
                notificationsEnabled: filter.notificationsEnabled
            )
        }

        // Capture settings. The menu-bar filter is referenced by name
        // so it can be re-resolved against the imported filters.
        let settings = SettingsManager.shared
        let menuBarFilterName = settings.menuBarFilterID.flatMap { idString in
            filters.first(where: { $0.id.uuidString == idString })?.name
        }
        let exportSettings = ExportSettings(
            refreshInterval: settings.refreshInterval,
            menuBarEnabled: settings.menuBarEnabled,
            menuBarFilterName: menuBarFilterName,
            labelBadgeConfigs: settings.labelBadgeConfigs,
            showAlertmanagerName: settings.showAlertmanagerName
        )

        let exportData = ExportData(
            alertmanagers: exportAlertmanagers,
            filters: exportFilters,
            settings: exportSettings,
            exportDate: Date(),
            version: "1.0"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try? encoder.encode(exportData)
    }

    /// Decodes an export blob and applies it to `modelContext`.
    ///
    /// Behavior:
    /// - **Alertmanagers**: skipped if an existing entry has the same
    ///   `(name, url)` pair; otherwise inserted. A name → id map is
    ///   built (using either new or existing ids) so filters can be
    ///   resolved.
    /// - **Filters**: always inserted; alertmanager names that don't
    ///   resolve are dropped from `selectedAlertmanagerIDs`.
    /// - **Settings**: when present, overwrite the current settings;
    ///   the menu-bar filter is re-resolved by name against the just
    ///   imported set.
    ///
    /// - Returns: counts of newly inserted alertmanagers and filters,
    ///   plus a flag indicating whether settings were restored.
    static func importData(
        from data: Data, modelContext: ModelContext, existingAlertmanagers: [Alertmanager]
    ) throws -> (alertmanagers: Int, filters: Int, settingsRestored: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exportData = try decoder.decode(ExportData.self, from: data)

        var importedAlertmanagersCount = 0
        // Maps every alertmanager name in the import (whether newly
        // inserted or matched against an existing entry) to its id, so
        // filter references can be rewritten.
        var alertmanagerNameToId: [String: UUID] = [:]

        for exportAlertmanager in exportData.alertmanagers {
            // De-duplicate against existing entries by `(name, url)` so
            // re-importing the same file is a no-op.
            let exists = existingAlertmanagers.contains { alertmanager in
                alertmanager.name == exportAlertmanager.name
                    && alertmanager.url == exportAlertmanager.url
            }

            if !exists {
                let alertmanager = Alertmanager(
                    name: exportAlertmanager.name,
                    url: exportAlertmanager.url,
                    isGrafana: exportAlertmanager.isGrafana,
                    grafanaAlertmanagers: exportAlertmanager.grafanaAlertmanagers,
                    authType: convertToAuthType(exportAlertmanager.authType)
                )
                alertmanager.sortOrder = exportAlertmanager.sortOrder ?? 0
                modelContext.insert(alertmanager)
                alertmanagerNameToId[exportAlertmanager.name] = alertmanager.id
                importedAlertmanagersCount += 1
            } else {
                // Already present — record the existing id so filters
                // can still resolve their references.
                if let existing = existingAlertmanagers.first(where: {
                    $0.name == exportAlertmanager.name
                }) {
                    alertmanagerNameToId[exportAlertmanager.name] = existing.id
                }
            }
        }

        var importedFiltersCount = 0
        // Tracks newly inserted filter ids so the menu-bar setting can
        // be re-resolved below.
        var filterNameToId: [String: UUID] = [:]

        for exportFilter in exportData.filters {
            // Drop alertmanager references whose names are unknown in
            // this store. (`compactMap` silently filters them out.)
            let alertmanagerIds = exportFilter.alertmanagerNames.compactMap { name in
                alertmanagerNameToId[name]
            }

            let filter = Filter(
                name: exportFilter.name,
                selectedAlertmanagerIDs: alertmanagerIds,
                states: exportFilter.states.compactMap(AlertState.init(rawValue:)),
                receivers: exportFilter.receivers,
                labelMatchers: exportFilter.labelMatchers.compactMap { exported in
                    guard let op = LabelMatcherOperator(rawValue: exported.op) else {
                        return nil
                    }
                    return LabelMatcher(key: exported.key, op: op, value: exported.value)
                }
            )
            filter.sortOrder = exportFilter.sortOrder ?? 0
            filter.notificationsEnabled = exportFilter.notificationsEnabled ?? false
            modelContext.insert(filter)
            filterNameToId[exportFilter.name] = filter.id
            importedFiltersCount += 1
        }

        // Persist immediately so subsequent UI reads (and the menu-bar
        // setting re-resolve below) see the new state.
        try modelContext.save()

        // Restore settings. The menu-bar filter is re-resolved by
        // name against the just-imported filter set; if it doesn't
        // resolve we clear the setting rather than leave a dangling
        // UUID reference.
        var settingsRestored = false
        if let exportDataSettings = exportData.settings {
            let settings = SettingsManager.shared
            settings.refreshInterval = exportDataSettings.refreshInterval
            settings.menuBarEnabled = exportDataSettings.menuBarEnabled
            if let filterName = exportDataSettings.menuBarFilterName,
                let filterId = filterNameToId[filterName]
            {
                settings.menuBarFilterID = filterId.uuidString
            } else {
                settings.menuBarFilterID = nil
            }
            if let configs = exportDataSettings.labelBadgeConfigs {
                settings.labelBadgeConfigs = configs
            }
            if let showAlertmanagerName = exportDataSettings.showAlertmanagerName {
                settings.showAlertmanagerName = showAlertmanagerName
            }
            settingsRestored = true
        }

        return (
            alertmanagers: importedAlertmanagersCount, filters: importedFiltersCount,
            settingsRestored: settingsRestored
        )
    }

    /// Converts the persisted `AuthenticationType` (enum with associated
    /// values) into the flatter `ExportAuthType` used in the JSON file.
    private static func convertAuthType(_ authType: AuthenticationType) -> ExportAuthType {
        switch authType {
        case .none:
            return .none
        case .basicAuth(let username, let password):
            return .basicAuth(username: username, password: password)
        case .tokenAuth(let tokenSource):
            switch tokenSource {
            case .direct(let token):
                return .token(token: token)
            case .file(let path):
                return .tokenFromFile(path: path)
            case .command(let command):
                return .tokenFromCommand(command: command)
            }
        }
    }

    /// Inverse of `convertAuthType`: rebuilds the nested
    /// `AuthenticationType` from the flat `ExportAuthType`.
    private static func convertToAuthType(_ exportAuthType: ExportAuthType) -> AuthenticationType {
        switch exportAuthType {
        case .none:
            return .none
        case .basicAuth(let username, let password):
            return .basicAuth(username: username, password: password)
        case .token(let token):
            return .tokenAuth(tokenSource: .direct(token: token))
        case .tokenFromFile(let path):
            return .tokenAuth(tokenSource: .file(path: path))
        case .tokenFromCommand(let command):
            return .tokenAuth(tokenSource: .command(command: command))
        }
    }
}
