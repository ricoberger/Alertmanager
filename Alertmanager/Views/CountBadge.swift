//
//  CountBadge.swift
//  Alertmanager
//

import SwiftUI

/// Capsule badge showing an alert count — red when greater than zero
/// (attention required), green when zero (all clear). Shared by the
/// sidebar row views.
struct CountBadge: View {
    /// The number to display.
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(count > 0 ? Color.red : Color.green)
            .clipShape(Capsule())
    }
}
