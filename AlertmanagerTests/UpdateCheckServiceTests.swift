//
//  UpdateCheckServiceTests.swift
//  AlertmanagerTests
//

import Foundation
import Testing

@testable import Alertmanager

@Suite("UpdateCheckService.isNewer")
struct UpdateCheckServiceVersionTests {

    @Test("Higher patch is newer")
    func higherPatch() {
        #expect(UpdateCheckService.isNewer(latest: "1.0.1", current: "1.0.0"))
    }

    @Test("Higher minor is newer")
    func higherMinor() {
        #expect(UpdateCheckService.isNewer(latest: "1.1.0", current: "1.0.9"))
    }

    @Test("Higher major is newer")
    func higherMajor() {
        #expect(UpdateCheckService.isNewer(latest: "2.0.0", current: "1.99.99"))
    }

    @Test("Equal versions are not newer")
    func equalVersions() {
        #expect(!UpdateCheckService.isNewer(latest: "1.0.0", current: "1.0.0"))
    }

    @Test("Lower version is not newer")
    func lowerVersion() {
        #expect(!UpdateCheckService.isNewer(latest: "1.0.0", current: "1.0.1"))
    }

    @Test("Leading v on tag is ignored")
    func ignoresLeadingV() {
        #expect(UpdateCheckService.isNewer(latest: "v1.2.0", current: "1.1.9"))
        #expect(!UpdateCheckService.isNewer(latest: "v1.0.0", current: "1.0.0"))
    }

    @Test("Trailing zero components count as equal")
    func trailingZeroComponents() {
        #expect(!UpdateCheckService.isNewer(latest: "1.2", current: "1.2.0"))
        #expect(!UpdateCheckService.isNewer(latest: "1.2.0", current: "1.2"))
        #expect(UpdateCheckService.isNewer(latest: "1.2.0.1", current: "1.2"))
    }

    @Test("Whitespace around versions is tolerated")
    func toleratesWhitespace() {
        #expect(UpdateCheckService.isNewer(latest: "  v1.2.0  ", current: "1.1.0"))
    }

    @Test("Numeric components compare numerically, not lexicographically")
    func numericComparison() {
        // "10" > "9" only when compared as integers — a string compare
        // would put "10" < "9".
        #expect(UpdateCheckService.isNewer(latest: "1.10.0", current: "1.9.0"))
    }
}
