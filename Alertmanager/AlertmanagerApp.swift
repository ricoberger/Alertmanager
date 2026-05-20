//
//  AlertmanagerApp.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Application entry point.
///
/// Wires together the SwiftData persistent store, the main window, the
/// optional menu bar popup, and the Settings scene. Also installs custom
/// menu commands that post `NotificationCenter` events consumed by
/// `ContentView` (add/import/export actions).
@main
struct AlertmanagerApp: App {
    /// User toggle that controls whether the `MenuBarExtra` is inserted
    /// into the system menu bar. Mirrored in `SettingsView`.
    @AppStorage("menuBarEnabled") private var menuBarEnabled: Bool = true

    /// Shared SwiftData container backing all scenes.
    ///
    /// Persists `Alertmanager` and `Filter` entities to
    /// `~/Library/Application Support/de.ricoberger.Alertmanager/default.sqlite`.
    /// Container creation is fatal — the app cannot function without
    /// persistence.
    ///
    /// UI tests launch the app with `-uiTestResetStore`, which redirects the
    /// SQLite file to a unique path under the temporary directory. This keeps
    /// each test launch isolated from prior runs (and from the user's real
    /// data) while still exercising the on-disk persistence path.
    ///
    /// UI tests can additionally pass `-uiTestSeedAlertmanagerURL <url>` to
    /// pre-populate the store with a single `Alertmanager` row pointed at the
    /// given URL (typically a loopback `FakeAlertmanagerServer`). This skips
    /// the form-typing flow when a test only cares about display behavior.
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Alertmanager.self,
            Filter.self,
        ])

        let url: URL
        if ProcessInfo.processInfo.arguments.contains("-uiTestResetStore") {
            url = FileManager.default.temporaryDirectory.appending(
                path: "Alertmanager-UITests-\(UUID().uuidString).sqlite")
        } else {
            url = URL.applicationSupportDirectory.appending(
                path: "de.ricoberger.Alertmanager/default.sqlite")
        }
        let modelConfiguration = ModelConfiguration(schema: schema, url: url)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            seedFromLaunchArgumentsIfNeeded(container: container)
            return container
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Main application window. Touching `NotificationService.shared` on
        // appear forces its initializer to run, which requests user
        // notification authorization and sets the delegate.
        WindowGroup {
            ContentView()
                .onAppear {
                    NotificationService.shared.configure(with: sharedModelContainer)
                    // One-shot version probe against the GitHub releases
                    // API. Subsequent `.onAppear` calls within the same
                    // session are no-ops — the banner is a launch hint.
                    UpdateCheckService.shared.checkForUpdate()
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            // Custom menu commands placed after the standard "Settings…"
            // item. Each button posts a `Notification` that `ContentView`
            // observes to drive the corresponding UI action — this avoids
            // threading bindings through the command builder.
            CommandGroup(after: .appSettings) {
                Divider()
                Button {
                    NotificationCenter.default.post(name: .addAlertmanager, object: nil)
                } label: {
                    Label("Add Alertmanager", systemImage: "plus.circle")
                }
                Button {
                    NotificationCenter.default.post(name: .addFilter, object: nil)
                } label: {
                    Label("Add Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                Divider()
                Button {
                    NotificationCenter.default.post(name: .importConfiguration, object: nil)
                } label: {
                    Label("Import Configuration", systemImage: "square.and.arrow.down")
                }
                Button {
                    NotificationCenter.default.post(name: .exportConfiguration, object: nil)
                } label: {
                    Label("Export Configuration", systemImage: "square.and.arrow.up")
                }
                Button {
                    NotificationCenter.default.post(name: .resetConfiguration, object: nil)
                } label: {
                    Label("Reset Configuration", systemImage: "arrow.counterclockwise")
                }
                Divider()
            }
        }

        // Menu bar popup. `isInserted` lets the user hide the icon entirely
        // from Settings without quitting the app. The `.window` style gives
        // a 500x400 panel rather than a classic menu list.
        MenuBarExtra("Alertmanager", systemImage: "bell.fill", isInserted: $menuBarEnabled) {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(sharedModelContainer)

        // Standard macOS Settings scene (⌘,). Shares the same container so
        // edits made here are immediately reflected elsewhere.
        Settings {
            SettingsView()
                .modelContainer(sharedModelContainer)
        }
    }
}

/// Inserts a single `Alertmanager` row when the app is launched with
/// `-uiTestSeedAlertmanagerURL <url>`. No-op outside of that flag.
///
/// Lets UI tests skip the create-alertmanager form flow and start from a
/// known-good store pointing at a loopback `FakeAlertmanagerServer`. Uses
/// `container.mainContext` so the views' `@Query` reads the seeded row on
/// first render, instead of racing a cross-context save notification.
@MainActor
private func seedFromLaunchArgumentsIfNeeded(container: ModelContainer) {
    let args = ProcessInfo.processInfo.arguments
    guard let flagIndex = args.firstIndex(of: "-uiTestSeedAlertmanagerURL"),
        flagIndex + 1 < args.count
    else { return }

    let url = args[flagIndex + 1]
    let context = container.mainContext
    context.insert(
        Alertmanager(
            name: "Test AM",
            url: url,
            isGrafana: false,
            grafanaAlertmanager: "",
            authType: .none
        )
    )
    do {
        try context.save()
    } catch {
        fatalError("UI test seed failed: \(error)")
    }
}
