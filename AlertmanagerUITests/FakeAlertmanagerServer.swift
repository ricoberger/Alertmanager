//
//  FakeAlertmanagerServer.swift
//  AlertmanagerUITests
//

import Foundation
import Network

/// Minimal in-test HTTP server that serves canned `GET /api/v2/alerts`
/// responses for the UI test suite.
///
/// Listens on `127.0.0.1` with an OS-assigned port. The resolved
/// `http://127.0.0.1:<port>` URL is passed to the app under test via the
/// `UI_TEST_SEED_ALERTMANAGER_URL` environment variable, so the seeded
/// `Alertmanager` row in SwiftData points at this listener.
///
/// The server is intentionally minimal: it reads up to one buffer of bytes
/// from each connection, ignores the request line, and writes the configured
/// response. That's enough to exercise the app's fetch + render path for
/// the populated, empty, and error-status sidebar states without dragging
/// in a third-party HTTP library.
final class FakeAlertmanagerServer {
    /// Canned response served on the next `/api/v2/alerts` request.
    enum Response {
        /// HTTP 200 with the supplied JSON body as `application/json`.
        case alerts(json: String)
        /// HTTP `code` with an empty body — used to verify the app's
        /// error-state sidebar badge.
        case status(Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeAlertmanagerServer")
    private var response: Response

    /// Port the listener bound to. Valid only after `start()` returns.
    private(set) var port: UInt16 = 0

    /// Loopback base URL pointing at this listener. Pass to the app via
    /// the `UI_TEST_SEED_ALERTMANAGER_URL` environment variable.
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(response: Response) throws {
        self.response = response
        self.listener = try NWListener(using: .tcp)
    }

    /// Binds the listener and blocks until it reaches the `.ready` state, so
    /// callers can read `port` immediately after `start()` returns. Throws
    /// if the listener does not become ready within 5 seconds.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var readyError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener.port {
                    self.port = p.rawValue
                }
                ready.signal()
            case .failed(let error):
                readyError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + .seconds(5)) == .timedOut {
            throw NSError(
                domain: "FakeAlertmanagerServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Listener did not become ready in time"])
        }
        if let readyError {
            throw readyError
        }
    }

    /// Cancels the listener. Safe to call multiple times.
    func stop() {
        listener.cancel()
    }

    /// Swaps the canned response served by subsequent connections.
    func setResponse(_ response: Response) {
        queue.async { self.response = response }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let payload = self.buildResponseBytes(for: self.response)
            connection.send(
                content: payload,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func buildResponseBytes(for response: Response) -> Data {
        switch response {
        case .alerts(let json):
            let body = Data(json.utf8)
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: application/json\r\n"
            header += "Content-Length: \(body.count)\r\n"
            header += "Connection: close\r\n\r\n"
            return Data(header.utf8) + body
        case .status(let code):
            var header = "HTTP/1.1 \(code) Error\r\n"
            header += "Content-Length: 0\r\n"
            header += "Connection: close\r\n\r\n"
            return Data(header.utf8)
        }
    }
}

/// Canned `/api/v2/alerts` payloads used by the UI tests.
enum FakeAlertmanagerPayloads {
    /// Single firing Watchdog alert — mirrors the canonical Alertmanager
    /// dead-man-switch alert that's expected to always be active.
    static let watchdog = """
        [{"annotations":{"description":"This is an alert meant to ensure that the entire alerting pipeline is functional. This alert is always firing, therefore it should always be firing in Alertmanager and always fire against a receiver. There are integrations with various notification mechanisms that send a notification when this alert is not firing. For example the \\"DeadMansSnitch\\" integration in PagerDuty.","summary":"Ensure entire alerting pipeline is functional"},"endsAt":"2026-05-20T05:02:41.872Z","fingerprint":"edaed4ef8a1a7ac2","receivers":[{"name":"slack"}],"startsAt":"2026-05-18T02:01:11.872Z","status":{"inhibitedBy":[],"mutedBy":[],"silencedBy":[],"state":"active"},"updatedAt":"2026-05-20T04:58:41.875Z","generatorURL":"http://demo.prometheus.io:9090/graph?g0.expr=vector%281%29&g0.tab=1","labels":{"alertname":"Watchdog","environment":"demo-prometheus-io.c.macro-mile-203600.internal","severity":"warning"}}]
        """

    /// Empty alert list — drives the "all clear" green count badge in the
    /// sidebar and the "No Alerts" state in the detail view.
    static let empty = "[]"
}
