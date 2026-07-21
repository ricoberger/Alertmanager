//
//  Filter.swift
//  Alertmanager
//

import Foundation
import SwiftData

/// Comparison operator applied between an alert label value and a
/// configured matcher value. Mirrors the operator set understood by
/// Prometheus / Alertmanager matchers.
enum LabelMatcherOperator: String, Codable, CaseIterable, Sendable, Hashable {
    /// Include alerts whose label value equals the configured value.
    case equal = "="
    /// Exclude alerts whose label value equals the configured value.
    case notEqual = "!="
    /// Include alerts whose label value matches the configured regex.
    case regexMatch = "=~"
    /// Exclude alerts whose label value matches the configured regex.
    case regexNotMatch = "!~"
}

/// A single label predicate used by `Filter`. Combines a label key, an
/// operator, and a comparison value (literal for `=`/`!=`, regex pattern
/// for `=~`/`!~`).
struct LabelMatcher: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier so SwiftUI lists can diff entries reliably even
    /// when the same key appears under different operators.
    var id: UUID
    /// Label name on the alert (e.g. `severity`, `instance`).
    var key: String
    /// Comparison operator applied between the label value and `value`.
    var op: LabelMatcherOperator
    /// Comparison value. Interpreted as a literal for `=`/`!=` and as an
    /// `NSRegularExpression` pattern for `=~`/`!~`.
    var value: String

    init(id: UUID = UUID(), key: String, op: LabelMatcherOperator, value: String) {
        self.id = id
        self.key = key
        self.op = op
        self.value = value
    }
}

/// A SwiftData-persisted filter that narrows the set of alerts shown in the
/// sidebar, detail view, and menu bar popup.
///
/// A filter combines four orthogonal predicates that are AND-ed together:
/// alertmanager scope, alert state, receiver name, and per-label matcher
/// evaluation. Filters can additionally opt in to local user notifications
/// when previously-unseen matching alerts arrive.
@Model
final class Filter {
    /// Stable identifier. Referenced from `@AppStorage("menuBarFilterID")`
    /// and used as the key for `NotificationService` "seen" tracking.
    var id: UUID

    /// User-facing display name shown in the sidebar.
    var name: String

    /// IDs of `Alertmanager` entries this filter applies to. An empty array
    /// means "all alertmanagers" — use `includesAlertmanager(withID:)`
    /// instead of testing membership directly so that semantic is applied
    /// consistently.
    var selectedAlertmanagerIDs: [UUID]

    /// Alert states to include (e.g. `.active`, `.suppressed`,
    /// `.unprocessed`). An empty array disables the state predicate.
    var states: [AlertState]

    /// Receiver names to include. An alert matches if any of its receivers'
    /// names appear in this list. An empty array disables the predicate.
    var receivers: [String]

    /// JSON-encoded backing storage for `labelMatchers`.
    ///
    /// SwiftData cannot persist arrays of custom structs directly, so the
    /// matcher list is encoded to `Data` and exposed via the `@Transient`
    /// `labelMatchers` accessor below.
    private var labelMatchersData: Data?

    /// Per-label predicates that must all match for an alert to pass.
    ///
    /// Reads decode `labelMatchersData` lazily; writes re-encode the new
    /// value. Decode/encode failures fall back to an empty array and log
    /// via `print`.
    @Transient
    var labelMatchers: [LabelMatcher] {
        get {
            guard let data = labelMatchersData else { return [] }
            do {
                return try JSONDecoder().decode([LabelMatcher].self, from: data)
            } catch {
                print("Failed to decode label matchers: \(error)")
                return []
            }
        }
        set {
            do {
                labelMatchersData = try JSONEncoder().encode(newValue)
            } catch {
                print("Failed to encode label matchers: \(error)")
                labelMatchersData = nil
            }
        }
    }

    /// Creation timestamp; used as a stable ordering tiebreak.
    var timestamp: Date

    /// User-controlled position within the sidebar list.
    var sortOrder: Int

    /// When `true`, `NotificationService` posts a local user notification
    /// the first time a new alert matching this filter is observed.
    var notificationsEnabled: Bool

    /// Creates a new filter.
    ///
    /// All parameters default so the initializer can be used to build an
    /// empty draft for the form view, then populated via `@Bindable`.
    ///
    /// - Parameters:
    ///   - id: Stable identifier; defaults to a fresh `UUID`.
    ///   - name: Display name.
    ///   - selectedAlertmanagerIDs: Alertmanager scope (empty = all).
    ///   - states: Alert states to include; defaults to `[.active]`.
    ///   - receivers: Receiver-name allowlist (empty = all).
    ///   - labelMatchers: Per-label matchers that must all evaluate true.
    ///   - timestamp: Creation date used for ordering tiebreaks.
    ///   - sortOrder: Position within the sidebar list.
    ///   - notificationsEnabled: Whether new matching alerts trigger local
    ///     user notifications.
    init(
        id: UUID = UUID(),
        name: String = "",
        selectedAlertmanagerIDs: [UUID] = [],
        states: [AlertState] = [.active],
        receivers: [String] = [],
        labelMatchers: [LabelMatcher] = [],
        timestamp: Date = Date(),
        sortOrder: Int = 0,
        notificationsEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.selectedAlertmanagerIDs = selectedAlertmanagerIDs
        self.states = states
        self.receivers = receivers
        self.timestamp = timestamp
        self.sortOrder = sortOrder
        self.notificationsEnabled = notificationsEnabled
        self.labelMatchers = labelMatchers
    }

    /// Whether this filter sources alerts from the given alertmanager.
    ///
    /// An empty `selectedAlertmanagerIDs` means "all alertmanagers".
    /// Centralised here so every alert surface (sidebar badge, detail
    /// view, menu bar popup, notifications) agrees on that semantic.
    ///
    /// - Parameter id: The `Alertmanager.id` to test.
    /// - Returns: `true` when the filter covers the alertmanager.
    func includesAlertmanager(withID id: UUID) -> Bool {
        selectedAlertmanagerIDs.isEmpty || selectedAlertmanagerIDs.contains(id)
    }

    /// Returns the subset of `alerts` that satisfy every configured
    /// predicate.
    ///
    /// Predicates are evaluated in this order, with empty configurations
    /// treated as "match all":
    /// 1. **State**: alert's `status.state` must be in `states`.
    /// 2. **Receiver**: at least one of the alert's receiver names must be
    ///    in `receivers`.
    /// 3. **Labels**: every entry in `labelMatchers` must evaluate true
    ///    against the alert's labels (see `LabelMatcher.evaluate(against:)`).
    ///
    /// - Parameter alerts: The full set of alerts to filter.
    /// - Returns: Alerts matching all configured predicates, preserving the
    ///   input order.
    func apply(to alerts: [GettableAlert]) -> [GettableAlert] {
        let matchers = labelMatchers

        return alerts.filter { alert in
            // State predicate: skip when no states configured.
            if !states.isEmpty {
                if !states.contains(alert.status.state) {
                    return false
                }
            }

            // Receiver predicate: alert must share at least one receiver name.
            if !receivers.isEmpty {
                let alertReceivers = alert.receivers.map { $0.name }
                let hasMatchingReceiver = receivers.contains { receiver in
                    alertReceivers.contains(receiver)
                }
                if !hasMatchingReceiver {
                    return false
                }
            }

            // Label predicates: every matcher must evaluate true.
            for matcher in matchers {
                if !matcher.evaluate(against: alert.labels) {
                    return false
                }
            }

            return true
        }
    }
}

extension LabelMatcher {
    /// Parses a search query string into an array of `LabelMatcher` values.
    ///
    /// The accepted syntax mirrors Prometheus/Alertmanager label-matcher
    /// notation, e.g.:
    ///
    ///     severity="critical", namespace=~"prod.*", job!="batch"
    ///
    /// Each term must follow the pattern:
    ///
    ///     <labelKey><op>"<value>"
    ///
    /// where `<op>` is one of `=`, `!=`, `=~`, `!~`.
    ///
    /// Terms are separated by commas. Whitespace around keys, operators,
    /// and values is trimmed. If any term cannot be parsed it is silently
    /// skipped so partial/in-progress input doesn't break the filter.
    ///
    /// - Parameter query: Raw search string typed by the user.
    /// - Returns: Zero or more matchers that can be applied with
    ///   `LabelMatcher.evaluate(against:)`.
    static func parse(query: String) -> [LabelMatcher] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // Split on commas; each chunk is one potential matcher.
        let terms = query.split(separator: ",", omittingEmptySubsequences: true)

        // Operators tried longest-first so `=~` / `!~` are matched before
        // the single-character `=`.
        let operators: [(String, LabelMatcherOperator)] = [
            ("=~", .regexMatch),
            ("!~", .regexNotMatch),
            ("!=", .notEqual),
            ("=", .equal),
        ]

        var matchers: [LabelMatcher] = []

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespaces)

            // Find the first operator that appears in this term.
            var matched: (key: String, op: LabelMatcherOperator, value: String)?
            for (opString, opEnum) in operators {
                if let range = trimmed.range(of: opString) {
                    let key = String(trimmed[trimmed.startIndex..<range.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    var value = String(trimmed[range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)

                    // Strip surrounding quotes if present.
                    if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }

                    guard !key.isEmpty else { break }
                    matched = (key, opEnum, value)
                    break
                }
            }

            if let m = matched {
                matchers.append(LabelMatcher(key: m.key, op: m.op, value: m.value))
            }
        }

        // If no valid matchers were parsed (e.g. the user typed a plain word
        // without an operator), treat the entire query as a regex pattern
        // applied to the `alertname` label.
        if matchers.isEmpty {
            matchers.append(
                LabelMatcher(
                    key: "alertname", op: .regexMatch,
                    value: query.trimmingCharacters(in: .whitespaces)))
        }

        return matchers
    }

    /// Evaluates the matcher against the given label set.
    ///
    /// Semantics:
    /// - `=`  : alert has label `key` whose value equals `value`.
    /// - `!=` : alert lacks label `key`, or its value differs from `value`.
    /// - `=~` : alert has label `key` whose value matches `value` as a
    ///          regex. If the pattern fails to compile, falls back to
    ///          exact-string equality.
    /// - `!~` : alert lacks label `key`, or its value does not match
    ///          `value` as a regex (with the same compile-failure
    ///          fallback).
    func evaluate(against labels: [String: String]) -> Bool {
        let labelValue = labels[key]

        switch op {
        case .equal:
            return labelValue == value
        case .notEqual:
            return labelValue != value
        case .regexMatch:
            guard let labelValue else { return false }
            return Self.regexMatches(pattern: value, in: labelValue)
        case .regexNotMatch:
            guard let labelValue else { return true }
            return !Self.regexMatches(pattern: value, in: labelValue)
        }
    }

    /// Compiles `pattern` and tests whether it matches anywhere in
    /// `string`. If the pattern fails to compile, falls back to
    /// exact-string equality so a malformed regex degrades gracefully
    /// rather than silently dropping every alert.
    private static func regexMatches(pattern: String, in string: String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(string.startIndex..., in: string)
            return regex.firstMatch(in: string, options: [], range: range) != nil
        }
        return string == pattern
    }
}
