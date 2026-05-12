//
//  SettingsManager.swift
//  Alertmanager
//

import Combine
import Foundation
import SwiftUI

/// A user-defined mapping from a label key to a display color.
///
/// Instances are persisted as a JSON array in `UserDefaults` under the
/// `"labelBadgeConfigs"` key. The color is stored as a hex string so it
/// survives `UserDefaults` serialisation without importing `AppKit`.
struct LabelBadgeConfig: Codable, Identifiable, Equatable {
    /// Stable identifier for use with `ForEach`.
    var id: UUID
    /// The alert label key to match (e.g. `"namespace"`).
    var labelKey: String
    /// Six-digit RGB hex color string (e.g. `"FF5733"`).
    var colorHex: String

    init(id: UUID = UUID(), labelKey: String = "", colorHex: String = "6E6E6E") {
        self.id = id
        self.labelKey = labelKey
        self.colorHex = colorHex
    }

    /// Converts `colorHex` into a SwiftUI `Color`.
    var color: Color {
        Color(hex: colorHex) ?? .gray
    }
}

extension Color {
    /// Initialises a `Color` from a six-digit RGB hex string.
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Returns a six-digit hex string representation of the color (sRGB).
    var hexString: String {
        #if canImport(AppKit)
            let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
            let r = Int((nsColor.redComponent * 255).rounded())
            let g = Int((nsColor.greenComponent * 255).rounded())
            let b = Int((nsColor.blueComponent * 255).rounded())
            return String(format: "%02X%02X%02X", r, g, b)
        #else
            return "6E6E6E"
        #endif
    }
}

/// Process-wide observable wrapper around the app's `UserDefaults`-backed
/// settings.
///
/// Exposes published properties that views can bind to via
/// `@StateObject`/`@ObservedObject`. Each setter mirrors its value to
/// `UserDefaults` immediately through `didSet`, so changes are persistent
/// without an explicit save step.
///
/// Singleton because the same settings are read from multiple scenes
/// (main window, menu bar, settings) and the `@Observable`/`@AppStorage`
/// equivalents would each maintain their own state.
class SettingsManager: ObservableObject {
    /// Process-wide singleton.
    static let shared = SettingsManager()

    /// Polling cadence in seconds, shared by every alertmanager timer.
    /// Mirrored to the `"refreshInterval"` `UserDefaults` key.
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
        }
    }

    /// Whether the `MenuBarExtra` is shown in the system menu bar.
    /// Mirrored to the `"menuBarEnabled"` `UserDefaults` key. Also read
    /// directly via `@AppStorage("menuBarEnabled")` in `AlertmanagerApp`.
    @Published var menuBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(menuBarEnabled, forKey: "menuBarEnabled")
        }
    }

    /// UUID string of the filter that drives the menu-bar popup, or
    /// `nil` when none is selected. Mirrored to `"menuBarFilterID"`.
    /// Also read via `@AppStorage("menuBarFilterID")` in
    /// `MenuBarContentView`.
    @Published var menuBarFilterID: String? {
        didSet {
            UserDefaults.standard.set(menuBarFilterID, forKey: "menuBarFilterID")
        }
    }

    /// Whether the alertmanager name prefix is shown in the alert row title.
    /// Mirrored to the `"showAlertmanagerName"` `UserDefaults` key.
    @Published var showAlertmanagerName: Bool {
        didSet {
            UserDefaults.standard.set(showAlertmanagerName, forKey: "showAlertmanagerName")
        }
    }

    /// Ordered list of label-key → color mappings shown as badges in the
    /// alert row header. Persisted as JSON under `"labelBadgeConfigs"`.
    @Published var labelBadgeConfigs: [LabelBadgeConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(labelBadgeConfigs) {
                UserDefaults.standard.set(data, forKey: "labelBadgeConfigs")
            }
        }
    }

    /// AI backend configuration used by the per-alert "Analyze" button.
    /// Persisted as a JSON blob under `"aiConfig"` so the nested provider
    /// enum + system prompt round-trip cleanly. Defaults to `AIConfig.default`
    /// (OpenAI shape, empty key) on first launch — the analyze action is
    /// disabled until `isUsable` is true.
    @Published var aiConfig: AIConfig {
        didSet {
            if let data = try? JSONEncoder().encode(aiConfig) {
                UserDefaults.standard.set(data, forKey: "aiConfig")
            }
        }
    }

    /// Loads each preference from `UserDefaults`, applying defaults when
    /// the key is absent (60s refresh, menu bar enabled, no filter).
    private init() {
        self.refreshInterval =
            UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval ?? 60.0
        self.menuBarEnabled =
            UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true
        self.menuBarFilterID = UserDefaults.standard.string(forKey: "menuBarFilterID")
        self.showAlertmanagerName =
            UserDefaults.standard.object(forKey: "showAlertmanagerName") as? Bool ?? true

        if let data = UserDefaults.standard.data(forKey: "labelBadgeConfigs"),
            let configs = try? JSONDecoder().decode([LabelBadgeConfig].self, from: data)
        {
            self.labelBadgeConfigs = configs
        } else {
            self.labelBadgeConfigs = []
        }

        if let data = UserDefaults.standard.data(forKey: "aiConfig"),
            let config = try? JSONDecoder().decode(AIConfig.self, from: data)
        {
            self.aiConfig = config
        } else {
            self.aiConfig = .default
        }
    }

    /// Convenience accessor that exposes `refreshInterval` in whole
    /// minutes for the Settings picker. Reads truncate, writes multiply
    /// by 60 — the underlying `TimeInterval` remains the source of truth.
    var refreshIntervalMinutes: Int {
        get {
            return Int(refreshInterval / 60)
        }
        set {
            refreshInterval = TimeInterval(newValue * 60)
        }
    }
}
