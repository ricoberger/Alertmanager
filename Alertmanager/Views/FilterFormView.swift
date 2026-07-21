//
//  FilterFormView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Sheet form for creating or editing a `Filter`.
///
/// Operates in two modes:
/// - **Create**: when `filter` is `nil`, a fresh entity is inserted on
///   save and assigned the next `sortOrder`.
/// - **Edit**: when `filter` is non-`nil`, local state is seeded from the
///   existing entity in `.onAppear`, and the same entity is mutated on
///   save.
///
/// Local `@State` mirrors the model fields rather than binding into the
/// model directly, so Cancel discards changes without touching SwiftData.
struct FilterFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// All alertmanagers, used to render the source-selection toggles.
    @Query private var alertmanagers: [Alertmanager]

    /// Existing entity in edit mode; `nil` in create mode.
    var filter: Filter?

    // MARK: - Form state

    /// Display name.
    @State private var name: String = ""
    /// IDs of source alertmanagers to query.
    @State private var selectedAlertmanagers: Set<UUID> = []
    /// Alert states to include (empty disables the state predicate, i.e.
    /// alerts in any state match).
    @State private var selectedStates: Set<AlertState> = []
    /// Receiver-name allowlist.
    @State private var selectedReceivers: Set<String> = []
    /// Configured label matchers (key + operator + value).
    @State private var labelMatchers: [LabelMatcher] = []
    /// Working buffer for the "add label" key field.
    @State private var newLabelKey: String = ""
    /// Working buffer for the "add label" operator picker.
    @State private var newLabelOperator: LabelMatcherOperator = .equal
    /// Working buffer for the "add label" value/pattern field.
    @State private var newLabelValue: String = ""
    /// Working buffer for the "add receiver" text field.
    @State private var newReceiverName: String = ""
    /// Whether matching alerts trigger local user notifications.
    @State private var notificationsEnabled: Bool = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("filter-name-field")

                Toggle("Enable Notifications", isOn: $notificationsEnabled)
                    .accessibilityIdentifier("filter-notifications-toggle")
            }

            // Source-alertmanager toggles. Each toggle's binding inserts
            // or removes the alertmanager id from `selectedAlertmanagers`.
            Section("Alertmanagers") {
                if alertmanagers.isEmpty {
                    Text("No Alertmanagers available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(alertmanagers) { alertmanager in
                        Toggle(
                            alertmanager.name.isEmpty ? alertmanager.url : alertmanager.name,
                            isOn: Binding(
                                get: { selectedAlertmanagers.contains(alertmanager.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedAlertmanagers.insert(alertmanager.id)
                                    } else {
                                        selectedAlertmanagers.remove(alertmanager.id)
                                    }
                                }
                            )
                        )
                        .accessibilityIdentifier("filter-am-toggle-\(alertmanager.name)")
                    }
                }
            }

            // Alert-state toggles. Hand-rolled per state because
            // `AlertState` is a small fixed enum and each binding needs
            // its own insert/remove closure.
            Section("Alert States") {
                Toggle(
                    "Active",
                    isOn: Binding(
                        get: { selectedStates.contains(.active) },
                        set: { isSelected in
                            if isSelected {
                                selectedStates.insert(.active)
                            } else {
                                selectedStates.remove(.active)
                            }
                        }
                    ))
                Toggle(
                    "Suppressed",
                    isOn: Binding(
                        get: { selectedStates.contains(.suppressed) },
                        set: { isSelected in
                            if isSelected {
                                selectedStates.insert(.suppressed)
                            } else {
                                selectedStates.remove(.suppressed)
                            }
                        }
                    ))
                Toggle(
                    "Unprocessed",
                    isOn: Binding(
                        get: { selectedStates.contains(.unprocessed) },
                        set: { isSelected in
                            if isSelected {
                                selectedStates.insert(.unprocessed)
                            } else {
                                selectedStates.remove(.unprocessed)
                            }
                        }
                    ))
            }

            // Editable receiver-name list. Each row has a remove button;
            // the trailing row appends a new entry on Return or +.
            Section("Receivers") {
                ForEach(Array(selectedReceivers), id: \.self) { receiver in
                    HStack {
                        Text(receiver)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: {
                            selectedReceivers.remove(receiver)
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("Add Receiver", text: $newReceiverName, onCommit: addReceiver)
                        .textFieldStyle(.roundedBorder)
                    Button(action: addReceiver) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(newReceiverName.isEmpty)
                }
            }

            // Editable label-matcher list. Each entry pairs a label key
            // with one of the supported operators (`=`, `!=`, `=~`, `!~`)
            // and a value/pattern. See `LabelMatcher.evaluate(against:)`
            // for the per-operator semantics.
            Section("Label Filters") {
                ForEach(labelMatchers) { matcher in
                    HStack {
                        Text("\(matcher.key)\(matcher.op.rawValue)\"\(matcher.value)\"")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(action: {
                            labelMatchers.removeAll { $0.id == matcher.id }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField("Label Key", text: $newLabelKey)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Picker("Operator", selection: $newLabelOperator) {
                        ForEach(LabelMatcherOperator.allCases, id: \.self) { op in
                            Text(op.rawValue).tag(op)
                        }
                    }
                    .labelsHidden()
                    TextField("Label Value", text: $newLabelValue)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button(action: addLabelFilter) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .disabled(newLabelKey.isEmpty || newLabelValue.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(filter == nil ? "Add Filter" : "Edit Filter")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("filter-cancel-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveFilter()
                }
                // Minimal validity check: name and at least one source
                // alertmanager are required.
                .disabled(name.isEmpty || selectedAlertmanagers.isEmpty)
                .accessibilityIdentifier("filter-save-button")
            }
        }
        .frame(width: 500)
        .frame(minHeight: 250, maxHeight: 500)
        .onAppear {
            // Edit-mode seeding. Done in `.onAppear` rather than `init` so
            // the `@Query` for `alertmanagers` has run before the toggles
            // render (otherwise edit-mode initial selection wouldn't show).
            if let filter = filter {
                name = filter.name
                selectedAlertmanagers = Set(filter.selectedAlertmanagerIDs)
                selectedStates = Set(filter.states)
                selectedReceivers = Set(filter.receivers)
                labelMatchers = filter.labelMatchers
                notificationsEnabled = filter.notificationsEnabled
            }
        }
    }

    /// Adds the trimmed contents of `newReceiverName` to the receiver
    /// allowlist and clears the input.
    private func addReceiver() {
        guard !newReceiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        selectedReceivers.insert(newReceiverName.trimmingCharacters(in: .whitespacesAndNewlines))
        newReceiverName = ""
    }

    /// Appends a new `LabelMatcher` built from the current "add label"
    /// inputs and clears them. If a matcher with the same `(key, op)`
    /// pair already exists its value is overwritten in place.
    private func addLabelFilter() {
        let key = newLabelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newLabelValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty && !value.isEmpty else { return }

        if let index = labelMatchers.firstIndex(where: {
            $0.key == key && $0.op == newLabelOperator
        }) {
            labelMatchers[index].value = value
        } else {
            labelMatchers.append(LabelMatcher(key: key, op: newLabelOperator, value: value))
        }

        newLabelKey = ""
        newLabelValue = ""
        newLabelOperator = .equal
    }

    /// Persists the form contents.
    ///
    /// In edit mode the existing entity is mutated; in create mode a new
    /// entity is inserted with the next `sortOrder`. The model context is
    /// explicitly saved (rather than relying on autosave) so the change
    /// is visible to `@Query` consumers immediately. The sheet is
    /// dismissed only on a successful save.
    private func saveFilter() {
        if let filter = filter {
            // Edit mode: mutate in place.
            filter.name = name
            filter.selectedAlertmanagerIDs = Array(selectedAlertmanagers)
            filter.states = Array(selectedStates)
            filter.receivers = Array(selectedReceivers)
            filter.labelMatchers = labelMatchers
            filter.notificationsEnabled = notificationsEnabled
        } else {
            // Create mode: append at the end of the sidebar.
            let maxSortOrder =
                (try? modelContext.fetch(FetchDescriptor<Filter>()))?.map(\.sortOrder).max() ?? -1
            let newFilter = Filter(
                name: name,
                selectedAlertmanagerIDs: Array(selectedAlertmanagers),
                states: Array(selectedStates),
                receivers: Array(selectedReceivers),
                labelMatchers: labelMatchers,
                sortOrder: maxSortOrder + 1,
                notificationsEnabled: notificationsEnabled
            )
            modelContext.insert(newFilter)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            print("Failed to save filter: \(error)")
        }
    }
}
