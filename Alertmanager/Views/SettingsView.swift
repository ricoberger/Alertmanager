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
                Toggle(
                    "Show Alertmanager Name in Alert Title", isOn: $settings.showAlertmanagerName
                )
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
                // Master toggle for the AI feature. Controls whether the
                // per-alert "Analyze" button is rendered at all — when
                // off, the button is hidden everywhere in the app.
                Toggle("Enabled", isOn: $settings.aiConfig.enabled)
                    .accessibilityIdentifier("settings-ai-enabled-toggle")

                // The service speaks the OpenAI Chat Completions wire
                // format. OpenAI, Anthropic, Google's Gemini, Azure OpenAI,
                // Ollama and vLLM all expose an OpenAI-compatible endpoint,
                // so a single endpoint + key is enough — there is no
                // per-vendor provider picker.
                TextField("Endpoint", text: $settings.aiConfig.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-ai-endpoint-field")
                SecureField("API Key", text: $settings.aiConfig.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-ai-api-key-field")
                TextField("Model", text: $settings.aiConfig.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings-ai-model-field")

                VStack(alignment: .leading, spacing: 6) {
                    Text("System Prompt")
                    // `TextField(axis: .vertical)` would normally grow with
                    // content, but inside `Form(.grouped)` macOS injects
                    // an environment-level control alignment that right-
                    // aligns multi-line TextField content — and no public
                    // SwiftUI modifier overrides it. `TextEditor` is not
                    // subject to that override, so we use a TextEditor and
                    // drive its height with an invisible `Text` mirror so
                    // it grows with the prompt instead of scrolling.
                    AutoSizingTextEditor(text: $settings.aiConfig.systemPrompt)
                        .accessibilityIdentifier("settings-ai-system-prompt-editor")
                }
            } header: {
                Text("AI")
            }
        }
        .formStyle(.grouped)
        // Fixed width plus vertical-only fixedSize gives the standard macOS
        // Settings panel proportions while letting the form size itself to
        // its content height.
        .frame(width: 500)
        .frame(minHeight: 250, maxHeight: 500)
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

/// A self-sizing multi-line editor used by the AI section's System
/// Prompt field.
///
/// SwiftUI's `TextEditor` always scrolls internally — its frame doesn't
/// grow with the content. `TextField(axis: .vertical)` does grow but is
/// forced to trailing alignment inside `Form(.grouped)` on macOS, with
/// no public modifier to override.
///
/// The fix here is the standard SwiftUI trick: render an invisible
/// `Text` mirror of the same content alongside the `TextEditor` in a
/// `ZStack`. The `Text` dictates the intrinsic height because it
/// supports `fixedSize(horizontal: false, vertical: true)`, and the
/// `TextEditor` stretches to fill it — yielding an editor that grows
/// line-by-line with the prompt and never needs internal scrolling.
private struct AutoSizingTextEditor: View {
    /// Two-way binding to the edited text.
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hidden Text view: same font + insets as the editor, holds
            // the same content plus a trailing space so an empty prompt
            // still reserves one line of height. `fixedSize(... vertical:
            // true)` makes this view report its full unwrapped height.
            Text(text.isEmpty ? " " : text + " ")
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
        }
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [Alertmanager.self, Filter.self], inMemory: true)
}
