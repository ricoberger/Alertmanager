//
//  AlertmanagerFormView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Sheet form for creating or editing an `Alertmanager` configuration.
///
/// Operates in two modes:
/// - **Create**: when `alertmanager` is `nil`, a fresh entity is inserted on
///   save and assigned the next `sortOrder`.
/// - **Edit**: when `alertmanager` is non-`nil`, the form's local state is
///   seeded from the existing entity in `init`, and the same entity is
///   mutated on save.
///
/// In both cases, polling is (re)started via `AlertsManager.startMonitoring`
/// after save so configuration changes (URL, auth) take effect immediately.
struct AlertmanagerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form state
    //
    // The view holds local `@State` for every field rather than binding
    // directly into the `Alertmanager` model so a Cancel discards changes
    // without touching SwiftData. Edit-mode initial values are seeded in
    // `init` from the supplied entity.

    /// Display name.
    @State private var name: String = ""
    /// Base URL of the backend.
    @State private var url: String = ""
    /// Whether this entry targets a Grafana-managed Alertmanager.
    @State private var isGrafana: Bool = false
    /// Grafana datasource UID to query (Grafana mode only).
    @State private var grafanaAlertmanager: String = ""
    /// Currently selected high-level auth strategy.
    @State private var selectedAuthType: AuthTypeOption = .none
    /// Basic-auth username (used when `selectedAuthType == .basicAuth`).
    @State private var basicAuthUsername: String = ""
    /// Basic-auth password (used when `selectedAuthType == .basicAuth`).
    @State private var basicAuthPassword: String = ""
    /// Token-source variant (used when `selectedAuthType == .tokenAuth`).
    @State private var selectedTokenSource: TokenSourceOption = .direct
    /// Verbatim token (used when `selectedTokenSource == .direct`).
    @State private var directToken: String = ""
    /// Path to a file containing the token (used when `.file`).
    @State private var filePath: String = ""
    /// Shell command emitting the token on stdout (used when `.command`).
    @State private var command: String = ""

    /// Existing entity in edit mode; `nil` in create mode.
    var alertmanager: Alertmanager?

    /// UI-only auth-type selector. Maps to `AuthenticationType` on save.
    enum AuthTypeOption: String, CaseIterable {
        case none = "None"
        case basicAuth = "Basic Auth"
        case tokenAuth = "Token Auth"
    }

    /// UI-only token-source selector. Maps to `TokenSource` on save.
    enum TokenSourceOption: String, CaseIterable {
        case direct = "Direct Token"
        case file = "File Path"
        case command = "Command"
    }

    /// Initializes the form. When `alertmanager` is provided, every
    /// `@State` is seeded from its current values so the form opens in
    /// edit mode pre-populated.
    init(alertmanager: Alertmanager? = nil) {
        self.alertmanager = alertmanager

        if let alertmanager = alertmanager {
            _name = State(initialValue: alertmanager.name)
            _url = State(initialValue: alertmanager.url)
            _isGrafana = State(initialValue: alertmanager.isGrafana)
            _grafanaAlertmanager = State(initialValue: alertmanager.grafanaAlertmanager)

            // Decompose the persisted enum-with-associated-values into the
            // flat UI selectors plus their corresponding text fields.
            switch alertmanager.authType {
            case .none:
                _selectedAuthType = State(initialValue: .none)
            case .basicAuth(let username, let password):
                _selectedAuthType = State(initialValue: .basicAuth)
                _basicAuthUsername = State(initialValue: username)
                _basicAuthPassword = State(initialValue: password)
            case .tokenAuth(let tokenSource):
                _selectedAuthType = State(initialValue: .tokenAuth)
                switch tokenSource {
                case .direct(let token):
                    _selectedTokenSource = State(initialValue: .direct)
                    _directToken = State(initialValue: token)
                case .file(let path):
                    _selectedTokenSource = State(initialValue: .file)
                    _filePath = State(initialValue: path)
                case .command(let cmd):
                    _selectedTokenSource = State(initialValue: .command)
                    _command = State(initialValue: cmd)
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("alertmanager-name-field")

                TextField("URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("alertmanager-url-field")

                Toggle("Is Grafana", isOn: $isGrafana)
                    .accessibilityIdentifier("alertmanager-is-grafana-toggle")

                if isGrafana {
                    TextField("Grafana Alertmanager", text: $grafanaAlertmanager)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("alertmanager-grafana-datasource-id-field")
                }
            }

            Section("Authentication") {
                // Top-level auth-type switcher. The body below renders only
                // the fields relevant to the selected variant.
                Picker("Type", selection: $selectedAuthType) {
                    ForEach(AuthTypeOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedAuthType {
                case .none:
                    Text("No authentication required")
                        .foregroundColor(.secondary)
                        .font(.caption)

                case .basicAuth:
                    TextField("Username", text: $basicAuthUsername)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $basicAuthPassword)
                        .textFieldStyle(.roundedBorder)

                case .tokenAuth:
                    // Nested switcher between token-source variants.
                    Picker("Token Source", selection: $selectedTokenSource) {
                        ForEach(TokenSourceOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    switch selectedTokenSource {
                    case .direct:
                        SecureField("Token", text: $directToken)
                            .textFieldStyle(.roundedBorder)
                    case .file:
                        HStack {
                            TextField("File Path", text: $filePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") {
                                selectFile()
                            }
                        }
                    case .command:
                        // Multi-line input for shell commands. The command
                        // is later executed via `/bin/sh -c` at request time.
                        TextField("Command", text: $command, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(alertmanager == nil ? "Add Alertmanager" : "Edit Alertmanager")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier("alertmanager-cancel-button")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveAlertmanager()
                }
                // Minimal validity check: name and URL must be non-empty.
                .disabled(name.isEmpty || url.isEmpty)
                .accessibilityIdentifier("alertmanager-save-button")
            }
        }
        .frame(width: 500)
        .frame(minHeight: 250, maxHeight: 500)
    }

    /// Presents an `NSOpenPanel` and writes the chosen path into
    /// `filePath`. Used by the `.file` token source row.
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                filePath = url.path
            }
        }
    }

    /// Reassembles the nested `AuthenticationType` from the flat form-state
    /// selectors. Extracted as a static function so it can be unit-tested
    /// without instantiating the view.
    static func buildAuthType(
        selectedAuth: AuthTypeOption,
        basicUsername: String,
        basicPassword: String,
        selectedTokenSource: TokenSourceOption,
        directToken: String,
        filePath: String,
        command: String
    ) -> AuthenticationType {
        switch selectedAuth {
        case .none:
            return AuthenticationType.none
        case .basicAuth:
            return .basicAuth(username: basicUsername, password: basicPassword)
        case .tokenAuth:
            switch selectedTokenSource {
            case .direct:
                return .tokenAuth(tokenSource: .direct(token: directToken))
            case .file:
                return .tokenAuth(tokenSource: .file(path: filePath))
            case .command:
                return .tokenAuth(tokenSource: .command(command: command))
            }
        }
    }

    /// Persists the form contents.
    ///
    /// Reassembles the nested `AuthenticationType` from the flat UI
    /// selectors, then either mutates the existing entity (edit mode) or
    /// inserts a new one with the next `sortOrder` (create mode). In both
    /// cases polling is restarted so the change takes effect immediately.
    /// The model context is explicitly saved (matching `FilterFormView`)
    /// so the change is visible to `@Query` consumers immediately; the
    /// sheet is dismissed only on a successful save.
    private func saveAlertmanager() {
        let authType = Self.buildAuthType(
            selectedAuth: selectedAuthType,
            basicUsername: basicAuthUsername,
            basicPassword: basicAuthPassword,
            selectedTokenSource: selectedTokenSource,
            directToken: directToken,
            filePath: filePath,
            command: command
        )

        if let alertmanager = alertmanager {
            // Edit mode: mutate the existing entity in place.
            alertmanager.name = name
            alertmanager.url = url
            alertmanager.isGrafana = isGrafana
            alertmanager.grafanaAlertmanager = grafanaAlertmanager
            alertmanager.authType = authType

            // Restart polling so URL/auth changes take effect immediately.
            AlertsManager.shared.startMonitoring(alertmanager: alertmanager)
        } else {
            // Create mode: append at the end of the sidebar by computing
            // one past the current maximum `sortOrder`.
            let maxSortOrder =
                (try? modelContext.fetch(FetchDescriptor<Alertmanager>()))?.map(\.sortOrder).max()
                ?? -1
            let newAlertmanager = Alertmanager(
                name: name,
                url: url,
                isGrafana: isGrafana,
                grafanaAlertmanager: grafanaAlertmanager,
                authType: authType,
                sortOrder: maxSortOrder + 1
            )
            modelContext.insert(newAlertmanager)

            AlertsManager.shared.startMonitoring(alertmanager: newAlertmanager)
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            print("Failed to save alertmanager: \(error)")
        }
    }
}

#Preview {
    AlertmanagerFormView()
        .modelContainer(for: Alertmanager.self, inMemory: true)
}
