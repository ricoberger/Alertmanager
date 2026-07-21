//
//  AnalysisManager.swift
//  Alertmanager
//

import Foundation

/// Process-wide singleton that runs the user-defined "Analyze" command for an
/// alert and tracks the resulting analysis files.
///
/// Responsibilities:
/// - Owns the fixed output directory
///   (`…/Application Support/de.ricoberger.Alertmanager/analyses/`) where
///   analysis files are expected to land. The command is launched with this
///   directory as its working directory, so a bare `{{filename}}` resolves
///   there.
/// - Derives a deterministic, filesystem-safe filename per alert firing
///   (`<sanitized-alertname>_<ISO8601-basic-UTC>.md`) so the same name is used
///   both when telling the command where to write and when checking for an
///   existing file.
/// - Executes the command via `/bin/sh -c` **fire-and-forget** on a background
///   queue (no UI blocking, no spinner). Failures are logged via `print` only.
/// - Deduplicates concurrent launches by filename so repeated clicks while a
///   run is in flight don't spawn duplicate processes.
/// - Watches the output directory with a `DispatchSource` and posts
///   `.analysisFilesDidChange` when its contents change, so rows can flip from
///   "Analyze" to "Analysis" the moment a file appears.
///
/// Requires the app to remain non-sandboxed — launching `Process` /
/// `/bin/sh -c` is unavailable in the sandbox (same constraint as
/// `TokenSource.command`).
@MainActor
final class AnalysisManager {
    /// Process-wide singleton. Shared so the output-directory watcher and the
    /// in-flight dedup set are visible to both the main window and the
    /// `MenuBarExtra`.
    static let shared = AnalysisManager()

    /// Fixed directory where analysis files are written and looked up. Mirrors
    /// the SwiftData store location under Application Support and is **not**
    /// user-configurable.
    let outputDirectory: URL = URL.applicationSupportDirectory.appending(
        path: "de.ricoberger.Alertmanager/analyses", directoryHint: .isDirectory)

    /// Filenames for which a command launch is currently in flight. Used to
    /// ignore duplicate clicks for the same alert firing until the process
    /// exits, and to drive the "Analyzing…" spinner state on the button.
    ///
    /// Mutations post `.analysisRunsDidChange` so observing rows can update
    /// their running state. Both mutation sites run on the main actor.
    private var inFlightFileNames: Set<String> = [] {
        didSet {
            NotificationCenter.default.post(name: .analysisRunsDidChange, object: nil)
        }
    }

    /// Directory-change watcher. Retained so it keeps delivering events.
    private var directorySource: DispatchSourceFileSystemObject?

    private init() {}

    // MARK: - Lifecycle

    /// Creates the output directory (if missing) and begins watching it for
    /// changes. Idempotent — safe to call from multiple `.onAppear` handlers.
    func start() {
        ensureOutputDirectoryExists()
        startWatching()
    }

    // MARK: - Filenames

    /// Deterministic, filesystem-safe filename for `alert`'s current firing:
    /// `<sanitized-alertname>_<ISO8601-basic-UTC>.md`
    /// (e.g. `HighMemoryUsage_20260707T174501Z.md`).
    ///
    /// `startsAt` is stable across polls for a given firing, so the name is
    /// stable too — one file per firing cycle. The `alertname` is sanitized by
    /// replacing every character outside `[A-Za-z0-9._-]` with `-`.
    func fileName(for alert: GettableAlert) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let sanitized = String(
            alert.alertName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: alert.startsAt)

        return "\(sanitized)_\(timestamp).md"
    }

    /// Parses an analysis filename produced by `fileName(for:)` back into its
    /// components: `<sanitized-alertname>_<yyyyMMddTHHmmssZ>.md`.
    ///
    /// The returned `alertName` is the **sanitized** form stored in the file
    /// name (characters outside `[A-Za-z0-9._-]` were replaced with `-` when
    /// the file was written), not necessarily the original alert label. The
    /// timestamp is split at the *last* underscore so alert names that
    /// themselves contain underscores parse correctly.
    ///
    /// - Returns: `nil` when `fileName` doesn't have the expected shape or the
    ///   timestamp can't be parsed.
    nonisolated static func parseFileName(_ fileName: String)
        -> (alertName: String, startsAt: Date)?
    {
        guard fileName.hasSuffix(".md") else { return nil }
        let base = String(fileName.dropLast(3))  // strip ".md"

        guard let underscore = base.range(of: "_", options: .backwards) else { return nil }
        let namePart = String(base[base.startIndex..<underscore.lowerBound])
        let stampPart = String(base[underscore.upperBound...])
        guard !namePart.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.isLenient = false
        guard let date = formatter.date(from: stampPart) else { return nil }

        return (namePart, date)
    }

    /// Absolute URL of the analysis file for `alert` inside `outputDirectory`.
    func fileURL(for alert: GettableAlert) -> URL {
        outputDirectory.appending(path: fileName(for: alert))
    }

    /// `true` when an analysis file for `alert` already exists on disk.
    func analysisExists(for alert: GettableAlert) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: alert).path)
    }

    /// `true` while a command launched for `alert`'s current firing is still
    /// running (its process has not yet exited).
    func isRunning(for alert: GettableAlert) -> Bool {
        inFlightFileNames.contains(fileName(for: alert))
    }

    /// Opens the existing analysis file for `alert` with the user's default
    /// handler for its type, via `/usr/bin/open`.
    ///
    /// `NSWorkspace.shared.open(_ url:)` is deliberately **not** used here: the
    /// default Markdown handler is often a wrapper (e.g. an Automator
    /// application that launches an editor inside a terminal). The single-URL
    /// `NSWorkspace` call merely launches such a wrapper without delivering the
    /// document, opening a blank window. `/usr/bin/open <path>` passes the file
    /// through as a document — matching what the user gets from the shell.
    func openAnalysis(for alert: GettableAlert) {
        let path = fileURL(for: alert).path
        print("AnalysisManager: opening analysis file: \(path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        do {
            try process.run()
        } catch {
            print("AnalysisManager: failed to open analysis file: \(error.localizedDescription)")
        }
    }

    // MARK: - Running

    /// Resolves the alert markdown, substitutes it and the filename into the
    /// configured command, and launches it fire-and-forget.
    ///
    /// Does nothing when the command setting is empty, or when a run for the
    /// same filename is already in flight. Markdown is built exactly as the
    /// "Copy as Markdown" action does (including resolved credentials), then
    /// substituted for `{{markdown}}`; the computed filename is substituted for
    /// `{{filename}}`.
    func analyze(for alert: GettableAlert, alertmanager: Alertmanager) async {
        let command = SettingsManager.shared.analyzeCommand.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let name = fileName(for: alert)
        guard !inFlightFileNames.contains(name) else {
            print("AnalysisManager: analysis already in flight for \(name); ignoring click")
            return
        }
        inFlightFileNames.insert(name)

        ensureOutputDirectoryExists()

        // Markdown resolution can require async I/O (token command / file), so
        // it happens here on the main actor before we hop to a background queue
        // to launch the process.
        let service = AlertmanagerService()
        let credentials = await service.resolveAuthCredentials(for: alertmanager)
        let markdown = AlertMarkdown.build(
            for: alert, alertmanager: alertmanager, authCredentials: credentials)

        let substituted =
            command
            .replacingOccurrences(of: "{{markdown}}", with: markdown)
            .replacingOccurrences(of: "{{filename}}", with: name)

        let directory = outputDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            Self.runDetachedShellCommand(substituted, workingDirectory: directory)
            Task { @MainActor in
                AnalysisManager.shared.inFlightFileNames.remove(name)
            }
        }
    }

    /// Synchronously runs `command` via `/bin/sh -c` with `workingDirectory` as
    /// its current directory. Must be called from a background queue — it
    /// blocks for the full duration of the (potentially long-running) command.
    ///
    /// The child inherits the current environment with the same two
    /// adjustments as `AlertmanagerService.runShellCommand`: `HOME` is set when
    /// missing, and `PATH` is augmented with `/usr/local/bin` and
    /// `/opt/homebrew/bin` so Homebrew-installed binaries (e.g. `copilot`)
    /// resolve when the app is launched from Finder rather than a login shell.
    ///
    /// stdout is discarded to `/dev/null`; stderr is drained to EOF (so a
    /// chatty command can't deadlock on a full pipe) and logged on a non-zero
    /// exit. This is fire-and-forget: the result is only logged, never
    /// surfaced in the UI.
    private nonisolated static func runDetachedShellCommand(
        _ command: String, workingDirectory: URL
    ) {
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if let existingPath = environment["PATH"] {
            environment["PATH"] = existingPath + ":/usr/local/bin:/opt/homebrew/bin"
        } else {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        }
        process.environment = environment

        do {
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let stderr =
                    String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print(
                    "AnalysisManager: command exited with status "
                        + "\(process.terminationStatus): \(stderr)")
            } else {
                print("AnalysisManager: command completed successfully")
            }
        } catch {
            print("AnalysisManager: failed to launch command: \(error.localizedDescription)")
        }
    }

    // MARK: - Watching

    /// Ensures `outputDirectory` exists, creating intermediate directories as
    /// needed. Logs on failure but does not throw — a missing directory simply
    /// means no analyses exist yet.
    private func ensureOutputDirectoryExists() {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            print(
                "AnalysisManager: failed to create output directory: "
                    + error.localizedDescription)
        }
    }

    /// Starts a `DispatchSource` watching `outputDirectory` for content
    /// changes, posting `.analysisFilesDidChange` (on the main queue) whenever
    /// a file is added, replaced, or removed. Idempotent — a second call is a
    /// no-op while a source is already active.
    private func startWatching() {
        guard directorySource == nil else { return }

        let descriptor = open(outputDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            print("AnalysisManager: failed to open output directory for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility))

        source.setEventHandler {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .analysisFilesDidChange, object: nil)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }

        directorySource = source
        source.resume()
    }
}
