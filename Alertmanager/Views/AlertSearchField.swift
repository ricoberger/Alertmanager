//
//  AlertSearchField.swift
//  Alertmanager
//

import SwiftUI

/// Toolbar search field shared by the alertmanager and filter detail views.
///
/// Holds the raw query text and, on submit, parses it into `LabelMatcher`
/// values via `LabelMatcher.parse(query:)` so the owning view can apply the
/// matchers on top of its own predicates.
struct AlertSearchField: View {
    /// Raw text typed into the field.
    @Binding var query: String

    /// Parsed label matchers derived from `query` on submit.
    @Binding var matchers: [LabelMatcher]

    var body: some View {
        TextField("Search", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 200, maxWidth: 400)
            .onSubmit {
                matchers = LabelMatcher.parse(query: query)
            }
    }
}
