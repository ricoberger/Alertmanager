//
//  SettingsView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Content of the standard macOS Settings scene (⌘,).
///
/// Exposes three preference groups backed by `SettingsManager`/`UserDefaults`:
/// - **General**: polling cadence used by every alertmanager timer.
/// - **Menu Bar**: whether the `MenuBarExtra` is shown, and which filter
///   drives its content.
/// - **Label Badges**: ordered list of label-key → color mappings that
///   are shown as badges next to the start time and severity in each alert row.
/// - **Analyze**: the user-defined shell command run by each alert row's
///   "Analyze" action (`SettingsManager.analyzeCommand`).
///
/// Changes to `refreshIntervalMinutes` propagate to `ContentView`, which
/// restarts all polling timers via its `.onChange` hook.
struct SettingsView: View {
    /// All filters, used to populate the menu-bar filter picker.
    @Query private var filters: [Filter]

    /// Observed `UserDefaults` wrapper. Bindings into its published
    /// properties write through to disk automatically.
    @StateObject private var settings = SettingsManager.shared

    /// Working buffer for the "add label badge" key field.
    @State private var newLabelKey: String = ""
    /// Working buffer for the "add label badge" color picker.
    @State private var newLabelColor: Color = .gray

    var body: some View {
        Form {
            Section {
                // Polling cadence shared by every alertmanager. Stored in
                // minutes for the picker; `SettingsManager` exposes a
                // `TimeInterval` derivative for the timer layer.
                HStack {
                    Text("Refresh Interval")
                    Spacer()
                    Picker("", selection: $settings.refreshIntervalMinutes) {
                        Text("1 minute").tag(1)
                        Text("2 minutes").tag(2)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .accessibilityIdentifier("settings-refresh-interval-picker")
                }

                // Whether the alertmanager name is prepended to the alert
                // title in each row. Disable to show only the alert name.
                Toggle("Show Alertmanager Name in Alert Title", isOn: $settings.showAlertmanagerName)
                    .accessibilityIdentifier("settings-show-alertmanager-name-toggle")

            } header: {
                Text("General")
            }

            Section {
                // Master toggle for the `MenuBarExtra`. Bound to the same
                // `@AppStorage("menuBarEnabled")` key read by `AlertmanagerApp`.
                Toggle("Enabled", isOn: $settings.menuBarEnabled)
                    .accessibilityIdentifier("settings-menu-bar-enabled-toggle")

                // Filter that drives the menu-bar popup contents. The "None"
                // tag intentionally maps to `Optional<String>.none` so the
                // empty-state UI in `MenuBarContentView` is shown.
                HStack {
                    Text("Filter")
                    Spacer()
                    Picker("", selection: $settings.menuBarFilterID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(filters.sorted(by: { $0.sortOrder < $1.sortOrder })) { filter in
                            Text(filter.name).tag(Optional(filter.id.uuidString))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .accessibilityIdentifier("settings-menu-bar-filter-picker")
                }
            } header: {
                Text("Menu Bar")
            }

            Section {
                // Each existing entry: color swatch + label key text, remove button.
                ForEach(settings.labelBadgeConfigs) { config in
                    HStack {
                        Text(config.labelKey)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        HStack(spacing: 20) {
                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: { Color(hex: config.colorHex) ?? .gray },
                                    set: { newColor in
                                        if let index = settings.labelBadgeConfigs.firstIndex(
                                            where: {
                                                $0.id == config.id
                                            })
                                        {
                                            settings.labelBadgeConfigs[index].colorHex =
                                                newColor.hexString
                                        }
                                    }
                                )
                            )
                            .labelsHidden()
                            .frame(width: 28)
                            Button(action: {
                                settings.labelBadgeConfigs.removeAll { $0.id == config.id }
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Add-new row: text field for label key + color picker + add button.
                HStack(spacing: 20) {
                    TextField("Label", text: $newLabelKey)
                        .textFieldStyle(.roundedBorder)
                    ColorPicker("", selection: $newLabelColor)
                        .labelsHidden()
                        .frame(width: 28)
                    Button(action: addLabelBadge) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(newLabelKey.isEmpty)
                }
            } header: {
                Text("Labels")
            }

            Section {
                // Shell command run by the "Analyze" action in each alert row.
                // Multi-line so heredoc-style invocations fit. While empty the
                // Analyze button is hidden.
                TextEditor(text: $settings.analyzeCommand)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("settings-analyze-command-editor")
            } header: {
                Text("Analyze")
            } footer: {
                Text(
                    "Run when the Analyze button is clicked. "
                        + "`{{markdown}}` is replaced with the alert as Markdown and "
                        + "`{{filename}}` with the file the analysis should be written to. "
                        + "The command runs with the analyses folder as its working directory."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                // Master toggle for the local HTTP API server (`APIServer`),
                // which subscribes to this value and starts/stops itself.
                Toggle("Enabled", isOn: $settings.apiServerEnabled)
                    .accessibilityIdentifier("settings-api-server-enabled-toggle")
            } header: {
                Text("API Server")
            } footer: {
                Text(
                    "Expose alerts, filters, and the Analyze action to other "
                        + "applications on this machine over HTTP at "
                        + "`http://127.0.0.1:9093`. Loopback only, no authentication."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        // Fixed width plus vertical-only fixedSize gives the standard macOS
        // Settings panel proportions while letting the form size itself to
        // its content height.
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Settings")
    }

    /// Appends a new `LabelBadgeConfig` from the current add-row inputs and
    /// resets the buffers.
    private func addLabelBadge() {
        let key = newLabelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        settings.labelBadgeConfigs.append(
            LabelBadgeConfig(labelKey: key, colorHex: newLabelColor.hexString)
        )
        newLabelKey = ""
        newLabelColor = .gray
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [Alertmanager.self, Filter.self], inMemory: true)
}
