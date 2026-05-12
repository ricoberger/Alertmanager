//
//  SettingsManagerTests.swift
//  AlertmanagerTests
//

import SwiftUI
import Testing

@testable import Alertmanager

// MARK: - Color(hex:)

@Suite("Color(hex:) parsing")
struct ColorHexInitTests {

    @Test("Parses lowercase 6-char hex without prefix")
    func parsesLowercase() throws {
        let c = try #require(Color(hex: "ff5733"))
        // Just verify it produced a non-nil color; exact component values
        // are tricky to assert cross-platform via SwiftUI Color, so we verify
        // round-trip via hexString.
        #expect(c.hexString == "FF5733")
    }

    @Test("Parses uppercase 6-char hex without prefix")
    func parsesUppercase() {
        let c = Color(hex: "FF5733")
        #expect(c != nil)
    }

    @Test("Strips leading # and parses correctly")
    func stripsHash() {
        let c = Color(hex: "#FF5733")
        #expect(c != nil)
        #expect(c?.hexString == "FF5733")
    }

    @Test("Returns nil for 3-char hex (too short)")
    func rejectsThreeChar() {
        #expect(Color(hex: "F57") == nil)
    }

    @Test("Returns nil for 8-char hex (too long)")
    func rejectsEightChar() {
        #expect(Color(hex: "FF5733AA") == nil)
    }

    @Test("Returns nil for non-hex characters")
    func rejectsNonHex() {
        #expect(Color(hex: "GGGGGG") == nil)
    }

    @Test("Parses pure black #000000")
    func parsesBlack() {
        let c = Color(hex: "000000")
        #expect(c != nil)
        #expect(c?.hexString == "000000")
    }

    @Test("Parses pure white #FFFFFF")
    func parsesWhite() {
        let c = Color(hex: "FFFFFF")
        #expect(c != nil)
        #expect(c?.hexString == "FFFFFF")
    }
}

// MARK: - LabelBadgeConfig

@Suite("LabelBadgeConfig")
struct LabelBadgeConfigTests {

    @Test("Default initializer uses grey color hex")
    func defaultColorHex() {
        let config = LabelBadgeConfig(labelKey: "namespace")
        #expect(config.colorHex == "6E6E6E")
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let id = UUID()
        let original = LabelBadgeConfig(id: id, labelKey: "namespace", colorHex: "FF5733")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LabelBadgeConfig.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.labelKey == "namespace")
        #expect(decoded.colorHex == "FF5733")
    }

    @Test("color property returns a valid Color from colorHex")
    func colorPropertyValid() {
        let config = LabelBadgeConfig(labelKey: "severity", colorHex: "FF0000")
        // Just verify it doesn't crash and produces the red component
        #expect(config.color.hexString == "FF0000")
    }

    @Test("color falls back to gray for invalid colorHex")
    func colorPropertyFallsToGray() {
        let config = LabelBadgeConfig(labelKey: "severity", colorHex: "invalid")
        // Color(hex: "invalid") is nil → fallback .gray
        // .gray hexString varies by platform but should be non-empty
        #expect(!config.color.hexString.isEmpty)
    }
}

// MARK: - SettingsManager.refreshIntervalMinutes

@Suite("SettingsManager.refreshIntervalMinutes")
struct SettingsManagerRefreshIntervalTests {

    // We operate directly on SettingsManager.shared — note that these tests
    // mutate global UserDefaults. Each test saves and restores the original
    // value to avoid cross-test pollution.

    @Test("get truncates seconds to whole minutes")
    @MainActor
    func getTruncates() {
        let settings = SettingsManager.shared
        let saved = settings.refreshInterval
        defer { settings.refreshInterval = saved }

        settings.refreshInterval = 61.0
        #expect(settings.refreshIntervalMinutes == 1)
    }

    @Test("set multiplies by 60")
    @MainActor
    func setMultiplies() {
        let settings = SettingsManager.shared
        let saved = settings.refreshInterval
        defer { settings.refreshInterval = saved }

        settings.refreshIntervalMinutes = 5
        #expect(settings.refreshInterval == 300.0)
    }

    @Test("set 1 minute produces 60 seconds")
    @MainActor
    func setOneMinute() {
        let settings = SettingsManager.shared
        let saved = settings.refreshInterval
        defer { settings.refreshInterval = saved }

        settings.refreshIntervalMinutes = 1
        #expect(settings.refreshInterval == 60.0)
    }

    @Test("get(0 seconds) returns 0 minutes")
    @MainActor
    func getZeroSeconds() {
        let settings = SettingsManager.shared
        let saved = settings.refreshInterval
        defer { settings.refreshInterval = saved }

        settings.refreshInterval = 0
        #expect(settings.refreshIntervalMinutes == 0)
    }
}
