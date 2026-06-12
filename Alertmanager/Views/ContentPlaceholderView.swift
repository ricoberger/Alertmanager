//
//  ContentPlaceholderView.swift
//  Alertmanager
//

import SwiftUI

/// Centered icon + title + message stack used for the app's various empty
/// states (no alerts, no menu-bar filter selected).
///
/// The component renders only the inner stack; call sites are responsible
/// for positioning (Spacer stacks or frames) and for attaching their own
/// accessibility identifiers.
struct ContentPlaceholderView: View {
    /// SF Symbol name rendered above the title.
    let systemImage: String

    /// Tint applied to the symbol.
    let iconColor: Color

    /// Headline shown below the icon.
    let title: String

    /// Secondary explanatory text.
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundColor(iconColor)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
