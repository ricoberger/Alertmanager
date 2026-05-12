//
//  UpdateAvailableBanner.swift
//  Alertmanager
//

import AppKit
import SwiftUI

/// Small overlay banner shown at the bottom of the main window when
/// `UpdateCheckService` has detected a newer release on GitHub.
///
/// The banner is rendered as an `.overlay` on top of `ContentView` so it
/// doesn't reflow the split-view layout. A "View Release" button opens the
/// specific release page on GitHub in the user's default browser; a
/// dismiss button closes the banner for the current session only — the
/// next launch re-checks and re-shows if the update is still applicable.
struct UpdateAvailableBanner: View {
    /// The update to advertise. Coming directly from
    /// `UpdateCheckService.availableUpdate`; the banner only renders when
    /// this is non-nil at the call site.
    let update: UpdateCheckService.AvailableUpdate

    /// Invoked when the user taps the dismiss (x) button.
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Available")
                    .font(.headline)
                Text(
                    "Version \(update.latestVersion) is available, you are running version \(update.currentVersion)."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                NSWorkspace.shared.open(update.releaseURL)
            } label: {
                Text("View Release")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("update-banner-view-release")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityIdentifier("update-banner-dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        .padding(24)
        .accessibilityIdentifier("update-banner")
    }
}
