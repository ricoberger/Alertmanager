//
//  AuthTypeBuilderTests.swift
//  AlertmanagerTests
//

import Testing

@testable import Alertmanager

@Suite("AlertmanagerFormView.buildAuthType")
struct AuthTypeBuilderTests {

    typealias Auth = AlertmanagerFormView.AuthTypeOption
    typealias Token = AlertmanagerFormView.TokenSourceOption

    @Test("none → .none")
    func noneCase() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .none,
            basicUsername: "", basicPassword: "",
            selectedTokenSource: .direct,
            directToken: "", filePath: "", command: ""
        )
        #expect(result == AuthenticationType.none)
    }

    @Test("basicAuth → .basicAuth with correct username and password")
    func basicAuthCase() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .basicAuth,
            basicUsername: "alice", basicPassword: "secret",
            selectedTokenSource: .direct,
            directToken: "", filePath: "", command: ""
        )
        #expect(result == .basicAuth(username: "alice", password: "secret"))
    }

    @Test("tokenAuth + direct → .tokenAuth(.direct(token:))")
    func tokenAuthDirect() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .tokenAuth,
            basicUsername: "", basicPassword: "",
            selectedTokenSource: .direct,
            directToken: "tok123", filePath: "", command: ""
        )
        #expect(result == .tokenAuth(tokenSource: .direct(token: "tok123")))
    }

    @Test("tokenAuth + file → .tokenAuth(.file(path:))")
    func tokenAuthFile() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .tokenAuth,
            basicUsername: "", basicPassword: "",
            selectedTokenSource: .file,
            directToken: "", filePath: "/var/run/token", command: ""
        )
        #expect(result == .tokenAuth(tokenSource: .file(path: "/var/run/token")))
    }

    @Test("tokenAuth + command → .tokenAuth(.command(command:))")
    func tokenAuthCommand() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .tokenAuth,
            basicUsername: "", basicPassword: "",
            selectedTokenSource: .command,
            directToken: "", filePath: "", command: "get-token.sh"
        )
        #expect(result == .tokenAuth(tokenSource: .command(command: "get-token.sh")))
    }

    @Test("basicAuth ignores token fields")
    func basicAuthIgnoresTokenFields() {
        let result = AlertmanagerFormView.buildAuthType(
            selectedAuth: .basicAuth,
            basicUsername: "u", basicPassword: "p",
            selectedTokenSource: .command,
            directToken: "tok", filePath: "/path", command: "cmd"
        )
        #expect(result == .basicAuth(username: "u", password: "p"))
    }
}
