//
//  AlertmanagerService.swift
//  Alertmanager
//

import Foundation

/// Errors surfaced by `AlertmanagerService`. Conforms to `LocalizedError`
/// so `errorDescription` can be displayed directly in the UI.
enum AlertmanagerError: LocalizedError {
    /// The configured base URL could not be parsed.
    case invalidURL
    /// The server responded with HTTP 401 or 403.
    case authenticationFailed
    /// Underlying transport failure (DNS, TLS, timeout, etc.) or a
    /// non-2xx, non-auth status code.
    case networkError(Error)
    /// The response body could not be decoded into the expected type.
    case decodingError(Error)
    /// Resolving a bearer token via file or shell command failed; the
    /// associated value is a human-readable reason.
    case tokenRetrievalFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Alertmanager URL"
        case .authenticationFailed:
            return "Authentication failed"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .tokenRetrievalFailed(let reason):
            return "Failed to retrieve token: \(reason)"
        }
    }
}

/// Minimal DTO for the Grafana `GET /api/datasources/uid/{uid}` response.
///
/// Only the `name` field is used; the rest of the payload is ignored.
private struct GrafanaDatasourceResponse: Decodable {
    let name: String
}

/// Stateless HTTP client for fetching alerts from a Prometheus
/// Alertmanager or a Grafana-managed Alertmanager.
///
/// One instance is constructed per call by `AlertsManager`; the type
/// holds no state and exists primarily as a namespace for the request
/// pipeline. All entry points are `@MainActor` to match the project-wide
/// default actor isolation.
@MainActor
class AlertmanagerService {

    // MARK: - Public Methods

    /// Fetches the current alert set for `alertmanager`, dispatching to
    /// the standard or Grafana-proxied API based on `isGrafana`.
    func fetchAlerts(for alertmanager: Alertmanager) async throws -> [GettableAlert] {
        if alertmanager.isGrafana {
            return try await fetchGrafanaAlerts(for: alertmanager)
        } else {
            return try await fetchStandardAlerts(for: alertmanager)
        }
    }

    // MARK: - Public Methods (Grafana datasource)

    /// Resolves the human-readable **name** of a Grafana alertmanager
    /// datasource from its UID by calling `GET {url}/api/datasources/uid/{uid}`.
    ///
    /// Grafana's silence creation URL requires the datasource *name* (e.g.
    /// `"Mimir"`) rather than its UID (e.g. `"abc123"`). The special
    /// built-in value `"grafana"` does not correspond to a datasource record
    /// and is returned verbatim without a network call.
    ///
    /// - Parameters:
    ///   - uid: The Grafana datasource UID to resolve.
    ///   - alertmanager: The Grafana `Alertmanager` configuration supplying
    ///     the base URL and auth credentials.
    /// - Returns: The datasource name if the API call succeeds, or `uid`
    ///   unchanged if the lookup fails (so callers always get *something*).
    func fetchDatasourceName(for uid: String, in alertmanager: Alertmanager) async -> String {
        // The built-in Grafana alertmanager is not a datasource; its UID
        // and name are both "grafana".
        guard uid != "grafana" else { return uid }

        let urlString = "\(alertmanager.url)/api/datasources/uid/\(uid)"
        guard let url = URL(string: urlString) else { return uid }

        var request = URLRequest(url: url)
        do {
            try await configureAuthentication(&request, for: alertmanager)
        } catch {
            print("fetchDatasourceName: auth config failed: \(error)")
            return uid
        }

        do {
            let response: GrafanaDatasourceResponse = try await performRequest(request)
            return response.name
        } catch {
            print("fetchDatasourceName: lookup failed for uid \(uid): \(error)")
            return uid
        }
    }

    // MARK: - Private Methods

    /// Fetches alerts from a standard Prometheus Alertmanager via
    /// `GET {url}/api/v2/alerts`.
    private func fetchStandardAlerts(for alertmanager: Alertmanager) async throws -> [GettableAlert]
    {
        let urlString = "\(alertmanager.url)/api/v2/alerts"
        guard let url = URL(string: urlString) else {
            throw AlertmanagerError.invalidURL
        }

        var request = URLRequest(url: url)
        try await configureAuthentication(&request, for: alertmanager)

        return try await performRequest(request)
    }

    /// Fetches alerts through Grafana's proxied Alertmanager API.
    ///
    /// Queries `GET {url}/api/alertmanager/{uid}/api/v2/alerts` using the
    /// Grafana datasource UID stored in `alertmanager.grafanaAlertmanager`.
    private func fetchGrafanaAlerts(for alertmanager: Alertmanager) async throws -> [GettableAlert]
    {
        let grafanaAlertmanager = alertmanager.grafanaAlertmanager
        guard !grafanaAlertmanager.isEmpty else {
            return []
        }

        let urlString =
            "\(alertmanager.url)/api/alertmanager/\(grafanaAlertmanager)/api/v2/alerts"
        guard let url = URL(string: urlString) else {
            throw AlertmanagerError.invalidURL
        }

        var request = URLRequest(url: url)
        try await configureAuthentication(&request, for: alertmanager)

        return try await performRequest(request)
    }

    /// Generic request executor.
    ///
    /// Maps HTTP status codes to `AlertmanagerError`:
    /// - 200–299 → success, decoded as `T` using ISO-8601 dates.
    /// - 401 / 403 → `.authenticationFailed`
    /// - other non-2xx → `.networkError(URLError(.badServerResponse))`
    ///
    /// Transport failures bubble up as `.networkError`; decode failures
    /// bubble up as `.decodingError`. `AlertmanagerError`s thrown from
    /// within are re-thrown unwrapped so their original case is preserved.
    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AlertmanagerError.networkError(URLError(.badServerResponse))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw AlertmanagerError.authenticationFailed
                }
                throw AlertmanagerError.networkError(URLError(.badServerResponse))
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw AlertmanagerError.decodingError(error)
            }
        } catch let error as AlertmanagerError {
            // Preserve the original case (e.g. `.authenticationFailed`)
            // rather than re-wrapping in `.networkError`.
            throw error
        } catch {
            throw AlertmanagerError.networkError(error)
        }
    }

    /// Applies the alertmanager's `authType` to the outgoing request.
    ///
    /// - `.none`: no header added.
    /// - `.basicAuth`: `Authorization: Basic <base64(user:pass)>`.
    /// - `.tokenAuth`: token resolved via `retrieveToken` (which may
    ///   read a file or execute a shell command), then sent as
    ///   `Authorization: Bearer <token>`.
    private func configureAuthentication(
        _ request: inout URLRequest, for alertmanager: Alertmanager
    )
        async throws
    {
        switch alertmanager.authType {
        case .none:
            break

        case .basicAuth(let username, let password):
            let credentials = "\(username):\(password)"
            if let credentialsData = credentials.data(using: .utf8) {
                let base64Credentials = credentialsData.base64EncodedString()
                request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            }

        case .tokenAuth(let tokenSource):
            let token = try await retrieveToken(from: tokenSource)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Resolves a bearer token from its configured source.
    ///
    /// - `.direct`: returned verbatim.
    /// - `.file`: file contents, trimmed of surrounding whitespace.
    /// - `.command`: stdout of `/bin/sh -c <command>`, trimmed.
    ///
    /// Resolved on every request, so file/command sources can serve
    /// short-lived or rotated tokens.
    private func retrieveToken(from source: TokenSource) async throws -> String {
        switch source {
        case .direct(let token):
            return token

        case .file(let path):
            do {
                let token = try String(contentsOfFile: path, encoding: .utf8)
                return token.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw AlertmanagerError.tokenRetrievalFailed(
                    "Failed to read token from file: \(error.localizedDescription)")
            }

        case .command(let command):
            return try await executeCommand(command)
        }
    }

    /// Executes `command` via `/bin/sh -c` and returns its trimmed stdout.
    ///
    /// The child process inherits the current environment with two
    /// adjustments:
    /// - `HOME` is set if missing (some tools require it).
    /// - `PATH` is augmented with `/usr/local/bin` and `/opt/homebrew/bin`
    ///   so Homebrew-installed binaries (e.g. `aws`, `gcloud`) resolve
    ///   even when the app is launched outside a shell.
    ///
    /// Stderr is captured and logged regardless of exit status. A
    /// non-zero exit or an empty stdout is reported as
    /// `.tokenRetrievalFailed` with as much context as possible.
    ///
    /// Requires the app to remain non-sandboxed (`Process` is not
    /// available in the sandbox).
    private func executeCommand(_ command: String) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment

        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }

        // Augment PATH so Homebrew-installed binaries are discoverable
        // when the app is launched from Finder/LaunchServices rather than
        // a login shell.
        if let existingPath = environment["PATH"] {
            environment["PATH"] = existingPath + ":/usr/local/bin:/opt/homebrew/bin"
        } else {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        }

        process.environment = environment

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output =
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput =
                String(data: errorData, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""

            // Surface stderr even on success — many tools emit warnings
            // or progress information there.
            if !errorOutput.isEmpty {
                print("Command stderr: \(errorOutput)")
            }

            guard process.terminationStatus == 0 else {
                let errorMsg =
                    errorOutput.isEmpty
                    ? "Command exited with status \(process.terminationStatus)" : errorOutput
                throw AlertmanagerError.tokenRetrievalFailed(errorMsg)
            }

            guard !output.isEmpty else {
                // Empty stdout is treated as a failure; include any stderr
                // we captured to make diagnosis easier.
                let debugInfo =
                    errorOutput.isEmpty ? "No error output available" : "stderr: \(errorOutput)"
                throw AlertmanagerError.tokenRetrievalFailed(
                    "Command returned empty output. \(debugInfo)")
            }

            return output
        } catch let error as AlertmanagerError {
            throw error
        } catch {
            throw AlertmanagerError.tokenRetrievalFailed(
                "Failed to execute command: \(error.localizedDescription)")
        }
    }
}
