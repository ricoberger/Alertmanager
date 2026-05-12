//
//  UpdateCheckService.swift
//  Alertmanager
//

import Combine
import Foundation

/// Checks the GitHub Releases API for a newer published version of the app.
///
/// The app's current version is taken from the `CFBundleShortVersionString`
/// `Info.plist` entry (the `MARKETING_VERSION` Xcode build setting). The
/// latest published release tag is fetched from
/// `https://api.github.com/repos/ricoberger/Alertmanager/releases/latest`.
///
/// Singleton because the banner that consumes `availableUpdate` is rendered
/// in `ContentView`, but the check itself fires from `AlertmanagerApp` on
/// launch and must outlive any single view.
@MainActor
final class UpdateCheckService: ObservableObject {
    /// Process-wide singleton.
    static let shared = UpdateCheckService()

    /// Available update, if a newer version was found on GitHub.
    ///
    /// `nil` means either the check hasn't run, the network call failed, or
    /// the installed app is already at the latest released version. The
    /// banner observes this property and shows/hides itself accordingly.
    @Published private(set) var availableUpdate: AvailableUpdate?

    /// One-shot guard so `checkForUpdate()` does nothing on subsequent
    /// launches *within* a single app session — the banner is meant as a
    /// startup hint, not a polling indicator.
    private var hasChecked = false

    /// GitHub REST endpoint returning the most recently published release.
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/ricoberger/Alertmanager/releases/latest")!

    private init() {}

    // MARK: - Public API

    /// Information about a newer version available on GitHub.
    struct AvailableUpdate: Equatable {
        /// Tag name as returned by GitHub (e.g. `"v1.2.3"`). Displayed
        /// verbatim in the banner so users see the same string GitHub uses.
        let latestVersion: String
        /// The currently running app version (without any `v` prefix), used
        /// to render the "1.0.0 → 1.2.3" hint.
        let currentVersion: String
        /// Canonical web URL for the release, taken from the GitHub API's
        /// `html_url` field (e.g.
        /// `https://github.com/ricoberger/Alertmanager/releases/tag/1.4.0`).
        /// Opened by the banner's "View Release" button.
        let releaseURL: URL
    }

    /// Performs the update check at most once per process lifetime.
    ///
    /// Safe to call from multiple `.onAppear` handlers — repeated calls
    /// after the first are no-ops.
    func checkForUpdate() {
        guard !hasChecked else { return }
        hasChecked = true

        Task { [weak self] in
            await self?.runCheck()
        }
    }

    // MARK: - Internals

    /// Resets the "already-checked" guard so the next `checkForUpdate()`
    /// performs a new network call. Used by tests; not exposed to UI code.
    func resetForTesting() {
        hasChecked = false
        availableUpdate = nil
    }

    private func runCheck() async {
        guard let current = Self.currentAppVersion() else {
            print("UpdateCheckService: could not read CFBundleShortVersionString; skipping check")
            return
        }

        do {
            var request = URLRequest(url: Self.latestReleaseAPI)
            // GitHub recommends a custom UA + the v3 Accept header.
            request.setValue("Alertmanager-macOS", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("UpdateCheckService: GitHub returned HTTP \(status); skipping")
                return
            }

            let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
            // Drafts and pre-releases are filtered out by the `/latest`
            // endpoint already, but double-check defensively.
            guard decoded.draft != true, decoded.prerelease != true else { return }

            let latestTag = decoded.tagName
            if Self.isNewer(latest: latestTag, current: current) {
                self.availableUpdate = AvailableUpdate(
                    latestVersion: latestTag,
                    currentVersion: current,
                    releaseURL: decoded.htmlURL
                )
            }
        } catch {
            print("UpdateCheckService: check failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Version helpers

    /// Reads the running app's `CFBundleShortVersionString` from the main
    /// bundle. Returns `nil` for unit-test hosts that don't ship a real
    /// `Info.plist`.
    private static func currentAppVersion() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Returns `true` when `latest` represents a strictly newer version
    /// than `current`.
    ///
    /// Both arguments may carry a leading `v` (GitHub release tags usually
    /// do) and any number of dot-separated numeric components. Trailing
    /// zero components are treated as equal (`1.2` == `1.2.0`). Components
    /// that fail to parse as integers fall back to a lexicographic
    /// comparison so non-numeric tags don't accidentally satisfy the
    /// "newer" test.
    ///
    /// Exposed `internal` so it can be exercised directly in unit tests.
    nonisolated static func isNewer(latest: String, current: String) -> Bool {
        let l = normalize(latest)
        let c = normalize(current)

        let lParts = l.split(separator: ".").map(String.init)
        let cParts = c.split(separator: ".").map(String.init)
        let count = max(lParts.count, cParts.count)

        for i in 0..<count {
            let lp = i < lParts.count ? lParts[i] : "0"
            let cp = i < cParts.count ? cParts[i] : "0"
            if let li = Int(lp), let ci = Int(cp) {
                if li > ci { return true }
                if li < ci { return false }
            } else {
                if lp > cp { return true }
                if lp < cp { return false }
            }
        }
        return false
    }

    /// Strips a leading `v`/`V` from a tag so `v1.2.3` compares cleanly
    /// against the bundle's `1.2.3` string.
    nonisolated private static func normalize(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    // MARK: - GitHub response shape

    /// Minimal projection of the `/releases/latest` JSON response. Only the
    /// fields the update check actually consumes are decoded.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }
}
