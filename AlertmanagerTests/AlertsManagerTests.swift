//
//  AlertsManagerTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlert(fingerprint: String) -> GettableAlert {
    GettableAlert(
        annotations: [:],
        receivers: [],
        fingerprint: fingerprint,
        startsAt: Date(),
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: .active, silencedBy: [], inhibitedBy: []),
        labels: [:],
        generatorURL: nil
    )
}

// MARK: - AlertsManager.stopMonitoring

@Suite("AlertsManager.stopMonitoring")
struct AlertsManagerStopMonitoringTests {

    @Test("Clears all cached state for the alertmanager")
    @MainActor
    func clearsCachedState() {
        let manager = AlertsManager.shared
        let alertmanager = Alertmanager(name: "Doomed", url: "http://doomed.example.com")

        // Seed every per-alertmanager cache as a completed fetch would.
        manager.alertsByAlertmanager[alertmanager.id] = [makeAlert(fingerprint: "fp1")]
        manager.lastRefreshByAlertmanager[alertmanager.id] = Date()
        manager.isLoadingByAlertmanager[alertmanager.id] = false
        manager.errorByAlertmanager[alertmanager.id] = "boom"
        manager.hasCompletedFetchByAlertmanager[alertmanager.id] = true

        manager.stopMonitoring(alertmanager: alertmanager)

        #expect(manager.alertsByAlertmanager[alertmanager.id] == nil)
        #expect(manager.lastRefreshByAlertmanager[alertmanager.id] == nil)
        #expect(manager.isLoadingByAlertmanager[alertmanager.id] == nil)
        #expect(manager.errorByAlertmanager[alertmanager.id] == nil)
        #expect(manager.hasCompletedFetchByAlertmanager[alertmanager.id] == nil)
    }

    @Test("Leaves other alertmanagers' caches untouched")
    @MainActor
    func leavesOtherEntriesAlone() {
        let manager = AlertsManager.shared
        let doomed = Alertmanager(name: "Doomed", url: "http://doomed.example.com")
        let survivor = Alertmanager(name: "Survivor", url: "http://survivor.example.com")

        manager.alertsByAlertmanager[doomed.id] = [makeAlert(fingerprint: "fp1")]
        manager.alertsByAlertmanager[survivor.id] = [makeAlert(fingerprint: "fp2")]

        manager.stopMonitoring(alertmanager: doomed)

        #expect(manager.alertsByAlertmanager[doomed.id] == nil)
        #expect(manager.alertsByAlertmanager[survivor.id]?.count == 1)

        // Clean up the shared singleton so other suites see no residue.
        manager.stopMonitoring(alertmanager: survivor)
    }
}
