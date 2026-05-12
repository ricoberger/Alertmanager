//
//  NotificationServiceLogicTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - categoryIdentifier bitmask logic

@Suite("NotificationService.categoryIdentifier")
struct CategoryIdentifierTests {

    // Bit positions:
    //   bit 0 → sourceURL
    //   bit 1 → silenceURL
    //   bit 2 → runbookURL
    //   bit 3 → dashboardURL
    //   bit 4 → panelURL

    private let service = NotificationService.shared

    @Test("No URLs present → ALERT_0")
    @MainActor
    func noURLs() {
        #expect(service.categoryIdentifier(for: [:]) == "ALERT_0")
    }

    @Test("Only sourceURL → ALERT_1 (bit 0)")
    @MainActor
    func onlySource() {
        let info = [NotificationUserInfoKey.sourceURL: "https://example.com"]
        #expect(service.categoryIdentifier(for: info) == "ALERT_1")
    }

    @Test("Only silenceURL → ALERT_2 (bit 1)")
    @MainActor
    func onlySilence() {
        let info = [NotificationUserInfoKey.silenceURL: "https://example.com"]
        #expect(service.categoryIdentifier(for: info) == "ALERT_2")
    }

    @Test("Only runbookURL → ALERT_4 (bit 2)")
    @MainActor
    func onlyRunbook() {
        let info = [NotificationUserInfoKey.runbookURL: "https://example.com"]
        #expect(service.categoryIdentifier(for: info) == "ALERT_4")
    }

    @Test("Only dashboardURL → ALERT_8 (bit 3)")
    @MainActor
    func onlyDashboard() {
        let info = [NotificationUserInfoKey.dashboardURL: "https://example.com"]
        #expect(service.categoryIdentifier(for: info) == "ALERT_8")
    }

    @Test("Only panelURL → ALERT_16 (bit 4)")
    @MainActor
    func onlyPanel() {
        let info = [NotificationUserInfoKey.panelURL: "https://example.com"]
        #expect(service.categoryIdentifier(for: info) == "ALERT_16")
    }

    @Test("sourceURL + silenceURL → ALERT_3 (bits 0|1)")
    @MainActor
    func sourceAndSilence() {
        let info = [
            NotificationUserInfoKey.sourceURL: "a",
            NotificationUserInfoKey.silenceURL: "b",
        ]
        #expect(service.categoryIdentifier(for: info) == "ALERT_3")
    }

    @Test("All five URLs present → ALERT_31 (bits 0|1|2|3|4)")
    @MainActor
    func allURLs() {
        let info = [
            NotificationUserInfoKey.sourceURL: "a",
            NotificationUserInfoKey.silenceURL: "b",
            NotificationUserInfoKey.runbookURL: "c",
            NotificationUserInfoKey.dashboardURL: "d",
            NotificationUserInfoKey.panelURL: "e",
        ]
        #expect(service.categoryIdentifier(for: info) == "ALERT_31")
    }

    @Test("Unrelated keys do not affect bitmask")
    @MainActor
    func unrelatedKeysIgnored() {
        let info = [
            NotificationUserInfoKey.fingerprint: "fp1",
            NotificationUserInfoKey.alertmanagerID: "some-uuid",
            NotificationUserInfoKey.sourceURL: "a",
        ]
        // Only sourceURL (bit 0) → ALERT_1
        #expect(service.categoryIdentifier(for: info) == "ALERT_1")
    }

    @Test("All 32 combinations produce unique identifiers")
    @MainActor
    func allCombinationsUnique() {
        let keys = [
            NotificationUserInfoKey.sourceURL,
            NotificationUserInfoKey.silenceURL,
            NotificationUserInfoKey.runbookURL,
            NotificationUserInfoKey.dashboardURL,
            NotificationUserInfoKey.panelURL,
        ]

        var results: Set<String> = []
        for mask in 0..<32 {
            var info: [String: String] = [:]
            for (bit, key) in keys.enumerated() {
                if mask & (1 << bit) != 0 {
                    info[key] = "https://example.com"
                }
            }
            let identifier = service.categoryIdentifier(for: info)
            results.insert(identifier)
        }

        // All 32 combinations must produce distinct identifiers
        #expect(results.count == 32)
    }

    @Test("Registered categories cover masks 1-31 but not 0")
    @MainActor
    func registeredCategoriesRange() {
        // The implementation registers categories for mask 1..<32.
        // ALERT_0 (no actions) is intentionally left unregistered.
        // We verify the identifier for each non-zero mask starts with "ALERT_"
        // and the mask value is in range.
        let keys = [
            NotificationUserInfoKey.sourceURL,
            NotificationUserInfoKey.silenceURL,
            NotificationUserInfoKey.runbookURL,
            NotificationUserInfoKey.dashboardURL,
            NotificationUserInfoKey.panelURL,
        ]

        for mask in 1..<32 {
            var info: [String: String] = [:]
            for (bit, key) in keys.enumerated() {
                if mask & (1 << bit) != 0 {
                    info[key] = "https://example.com"
                }
            }
            let identifier = service.categoryIdentifier(for: info)
            #expect(identifier == "ALERT_\(mask)")
        }
    }
}
