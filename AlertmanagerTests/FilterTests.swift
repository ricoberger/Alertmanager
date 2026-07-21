//
//  FilterTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

// MARK: - Helpers

private func makeAlert(
    fingerprint: String = "fp",
    state: AlertState = .active,
    receiverNames: [String] = [],
    labels: [String: String] = [:]
) -> GettableAlert {
    GettableAlert(
        annotations: [:],
        receivers: receiverNames.map { Receiver(name: $0) },
        fingerprint: fingerprint,
        startsAt: Date(),
        updatedAt: Date(),
        endsAt: Date(),
        status: AlertStatus(state: state, silencedBy: [], inhibitedBy: []),
        labels: labels,
        generatorURL: nil
    )
}

private func makeMatcher(key: String, op: LabelMatcherOperator, value: String) -> LabelMatcher {
    LabelMatcher(key: key, op: op, value: value)
}

// MARK: - LabelMatcher.evaluate

@Suite("LabelMatcher.evaluate — equal operator")
struct LabelMatcherEqualTests {

    @Test("= matches present label with exact value")
    func equalMatchesPresent() {
        let m = makeMatcher(key: "severity", op: .equal, value: "critical")
        #expect(m.evaluate(against: ["severity": "critical"]) == true)
    }

    @Test("= does not match present label with different value")
    func equalNoMatchDifferentValue() {
        let m = makeMatcher(key: "severity", op: .equal, value: "critical")
        #expect(m.evaluate(against: ["severity": "warning"]) == false)
    }

    @Test("= does not match absent label")
    func equalNoMatchAbsent() {
        let m = makeMatcher(key: "severity", op: .equal, value: "critical")
        #expect(m.evaluate(against: [:]) == false)
    }
}

@Suite("LabelMatcher.evaluate — notEqual operator")
struct LabelMatcherNotEqualTests {

    @Test("!= matches absent label (Prometheus semantics)")
    func notEqualMatchesAbsent() {
        let m = makeMatcher(key: "severity", op: .notEqual, value: "critical")
        #expect(m.evaluate(against: [:]) == true)
    }

    @Test("!= matches present label with different value")
    func notEqualMatchesDifferent() {
        let m = makeMatcher(key: "severity", op: .notEqual, value: "critical")
        #expect(m.evaluate(against: ["severity": "warning"]) == true)
    }

    @Test("!= does not match present label with equal value")
    func notEqualNoMatchSameValue() {
        let m = makeMatcher(key: "severity", op: .notEqual, value: "critical")
        #expect(m.evaluate(against: ["severity": "critical"]) == false)
    }
}

@Suite("LabelMatcher.evaluate — regexMatch operator")
struct LabelMatcherRegexMatchTests {

    @Test("=~ matches present label against valid regex")
    func regexMatchHits() {
        let m = makeMatcher(key: "alertname", op: .regexMatch, value: "High.*")
        #expect(m.evaluate(against: ["alertname": "HighCPU"]) == true)
    }

    @Test("=~ does not match present label that doesn't satisfy regex")
    func regexMatchMisses() {
        let m = makeMatcher(key: "alertname", op: .regexMatch, value: "High.*")
        #expect(m.evaluate(against: ["alertname": "LowMemory"]) == false)
    }

    @Test("=~ does not match absent label")
    func regexMatchAbsent() {
        let m = makeMatcher(key: "alertname", op: .regexMatch, value: ".*")
        #expect(m.evaluate(against: [:]) == false)
    }

    @Test("=~ falls back to exact-string equality when regex is invalid")
    func regexMatchInvalidPatternFallback() {
        // "[invalid" is not a valid regex — should fall back to exact equality
        let m = makeMatcher(key: "alertname", op: .regexMatch, value: "[invalid")
        #expect(m.evaluate(against: ["alertname": "[invalid"]) == true)
        #expect(m.evaluate(against: ["alertname": "anything"]) == false)
    }
}

@Suite("LabelMatcher.evaluate — regexNotMatch operator")
struct LabelMatcherRegexNotMatchTests {

    @Test("!~ matches absent label (Prometheus semantics)")
    func regexNotMatchAbsent() {
        let m = makeMatcher(key: "severity", op: .regexNotMatch, value: "critical")
        #expect(m.evaluate(against: [:]) == true)
    }

    @Test("!~ matches present label that does not satisfy regex")
    func regexNotMatchMisses() {
        let m = makeMatcher(key: "severity", op: .regexNotMatch, value: "crit.*")
        #expect(m.evaluate(against: ["severity": "warning"]) == true)
    }

    @Test("!~ does not match present label that satisfies regex")
    func regexNotMatchHits() {
        let m = makeMatcher(key: "severity", op: .regexNotMatch, value: "crit.*")
        #expect(m.evaluate(against: ["severity": "critical"]) == false)
    }

    @Test("!~ falls back to exact-string inequality when regex is invalid")
    func regexNotMatchInvalidPatternFallback() {
        let m = makeMatcher(key: "severity", op: .regexNotMatch, value: "[invalid")
        #expect(m.evaluate(against: ["severity": "[invalid"]) == false)
        #expect(m.evaluate(against: ["severity": "other"]) == true)
    }
}

// MARK: - LabelMatcher.parse

@Suite("LabelMatcher.parse")
struct LabelMatcherParseTests {

    @Test("Empty string returns empty array")
    func emptyString() {
        #expect(LabelMatcher.parse(query: "").isEmpty)
    }

    @Test("Whitespace-only string returns empty array")
    func whitespaceOnly() {
        #expect(LabelMatcher.parse(query: "   ").isEmpty)
    }

    @Test("Parses = operator")
    func parsesEqual() {
        let ms = LabelMatcher.parse(query: "severity=\"critical\"")
        #expect(ms.count == 1)
        #expect(ms[0].key == "severity")
        #expect(ms[0].op == .equal)
        #expect(ms[0].value == "critical")
    }

    @Test("Parses != operator")
    func parsesNotEqual() {
        let ms = LabelMatcher.parse(query: "severity!=\"warning\"")
        #expect(ms.count == 1)
        #expect(ms[0].op == .notEqual)
        #expect(ms[0].value == "warning")
    }

    @Test("Parses =~ operator")
    func parsesRegexMatch() {
        let ms = LabelMatcher.parse(query: "alertname=~\"High.*\"")
        #expect(ms.count == 1)
        #expect(ms[0].op == .regexMatch)
        #expect(ms[0].value == "High.*")
    }

    @Test("Parses !~ operator")
    func parsesRegexNotMatch() {
        let ms = LabelMatcher.parse(query: "alertname!~\"Batch.*\"")
        #expect(ms.count == 1)
        #expect(ms[0].op == .regexNotMatch)
    }

    @Test("Longest operator wins: =~ not confused with =")
    func longestOperatorWins() {
        // If `=` is matched before `=~`, we'd get value "~\"High.*\"" instead
        let ms = LabelMatcher.parse(query: "alertname=~\"High.*\"")
        #expect(ms[0].op == .regexMatch)
        #expect(ms[0].value == "High.*")
    }

    @Test("Parses multiple comma-separated terms")
    func multipleTerms() {
        let ms = LabelMatcher.parse(query: "severity=\"critical\", namespace=~\"prod.*\"")
        #expect(ms.count == 2)
        #expect(ms[0].key == "severity")
        #expect(ms[1].key == "namespace")
    }

    @Test("Strips surrounding quotes from value")
    func stripsQuotes() {
        let ms = LabelMatcher.parse(query: "k=\"v\"")
        #expect(ms[0].value == "v")
    }

    @Test("Parses unquoted value")
    func unquotedValue() {
        let ms = LabelMatcher.parse(query: "k=v")
        #expect(ms[0].value == "v")
    }

    @Test("Empty key causes term to be skipped")
    func emptyKeySkipped() {
        // A comma with no key before the operator
        let ms = LabelMatcher.parse(query: "=value")
        // No valid matcher key — plain text fallback to alertname =~ <query>
        #expect(ms.count == 1)
        #expect(ms[0].key == "alertname")
        #expect(ms[0].op == .regexMatch)
    }

    @Test("Plain text without operator falls back to alertname =~ query")
    func plainTextFallback() {
        let ms = LabelMatcher.parse(query: "HighCPU")
        #expect(ms.count == 1)
        #expect(ms[0].key == "alertname")
        #expect(ms[0].op == .regexMatch)
        #expect(ms[0].value == "HighCPU")
    }
}

// MARK: - Filter.apply

@Suite("Filter.apply")
struct FilterApplyTests {

    // MARK: state predicate

    @Test("Empty states array: all alerts pass state predicate")
    func emptyStatesMatchAll() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [])
        let alerts = [makeAlert(state: .active), makeAlert(fingerprint: "fp2", state: .suppressed)]
        let result = filter.apply(to: alerts)
        #expect(result.count == 2)
    }

    @Test("Non-empty states: only matching state passes")
    func stateFiltersCorrectly() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [.active])
        let alerts = [
            makeAlert(fingerprint: "a", state: .active),
            makeAlert(fingerprint: "b", state: .suppressed),
        ]
        let result = filter.apply(to: alerts)
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "a")
    }

    // MARK: receiver predicate

    @Test("Empty receivers array: all alerts pass receiver predicate")
    func emptyReceiversMatchAll() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [], receivers: [])
        let alerts = [
            makeAlert(receiverNames: ["slack"]), makeAlert(fingerprint: "fp2", receiverNames: []),
        ]
        let result = filter.apply(to: alerts)
        #expect(result.count == 2)
    }

    @Test("Non-empty receivers: alert passes if any receiver matches")
    func receiversIntersection() {
        let filter = Filter(
            name: "f", selectedAlertmanagerIDs: [], states: [], receivers: ["slack"])
        let alerts = [
            makeAlert(fingerprint: "a", receiverNames: ["slack", "email"]),
            makeAlert(fingerprint: "b", receiverNames: ["pager"]),
        ]
        let result = filter.apply(to: alerts)
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "a")
    }

    // MARK: label predicates

    @Test("Empty labelMatchers: all alerts pass")
    func emptyMatchersMatchAll() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [], labelMatchers: [])
        let alerts = [
            makeAlert(labels: ["foo": "bar"]), makeAlert(fingerprint: "fp2", labels: [:]),
        ]
        let result = filter.apply(to: alerts)
        #expect(result.count == 2)
    }

    @Test("Multiple matchers are AND-ed: alert must satisfy all")
    func matchersAreAnded() {
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [],
            states: [],
            labelMatchers: [
                makeMatcher(key: "severity", op: .equal, value: "critical"),
                makeMatcher(key: "namespace", op: .equal, value: "prod"),
            ]
        )
        let alerts = [
            makeAlert(fingerprint: "a", labels: ["severity": "critical", "namespace": "prod"]),
            makeAlert(fingerprint: "b", labels: ["severity": "critical", "namespace": "dev"]),
            makeAlert(fingerprint: "c", labels: ["severity": "warning", "namespace": "prod"]),
        ]
        let result = filter.apply(to: alerts)
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "a")
    }

    // MARK: ordering

    @Test("apply preserves input order")
    func preservesOrder() {
        let filter = Filter(name: "f", selectedAlertmanagerIDs: [], states: [.active])
        let alerts = ["z", "y", "x"].enumerated().map { i, fp in
            makeAlert(fingerprint: fp, state: .active)
        }
        let result = filter.apply(to: alerts)
        #expect(result.map(\.fingerprint) == ["z", "y", "x"])
    }

    // MARK: combined predicates

    @Test("All three predicates combined: AND semantics")
    func allPredicatesCombined() {
        let filter = Filter(
            name: "f",
            selectedAlertmanagerIDs: [],
            states: [.active],
            receivers: ["slack"],
            labelMatchers: [makeMatcher(key: "severity", op: .equal, value: "critical")]
        )
        let pass = makeAlert(
            fingerprint: "pass",
            state: .active,
            receiverNames: ["slack"],
            labels: ["severity": "critical"]
        )
        let failState = makeAlert(
            fingerprint: "failState",
            state: .suppressed,
            receiverNames: ["slack"],
            labels: ["severity": "critical"]
        )
        let failReceiver = makeAlert(
            fingerprint: "failReceiver",
            state: .active,
            receiverNames: ["email"],
            labels: ["severity": "critical"]
        )
        let failLabel = makeAlert(
            fingerprint: "failLabel",
            state: .active,
            receiverNames: ["slack"],
            labels: ["severity": "warning"]
        )
        let result = filter.apply(to: [pass, failState, failReceiver, failLabel])
        #expect(result.count == 1)
        #expect(result[0].fingerprint == "pass")
    }
}
