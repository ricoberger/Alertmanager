//
//  AIAnalysisService.swift
//  Alertmanager
//

import Combine
import Foundation

/// Drives the per-alert AI analysis flow.
///
/// Given a single firing alert, a Grafana alertmanager, and the user's
/// `AIConfig`, the service runs a tool-calling loop against the configured
/// AI endpoint:
///
/// 1. The alert (labels + annotations + start time + alertmanager URL) is
///    rendered as a user message and sent alongside the user-configured
///    system prompt.
/// 2. The AI is given a single tool — `grafana_request` — that executes an
///    authenticated HTTP request against the same Grafana instance the
///    alert came from, using the alertmanager's stored credentials.
/// 3. Each tool call response is appended to the conversation and the
///    next completion is requested. The loop terminates when the AI stops
///    requesting tools (and emits a final text answer), when the iteration
///    cap is hit, or when the caller calls `stop()`.
///
/// Speaks the OpenAI `chat/completions` wire format. Most modern vendors
/// (OpenAI, Anthropic, Google's Gemini, Azure OpenAI, Ollama, vLLM, …)
/// expose an OpenAI-compatible endpoint, so a single dispatch path is
/// enough — the user just configures the endpoint URL and key for their
/// provider of choice.
///
/// All state-mutating methods are `@MainActor` so SwiftUI observers see
/// consistent transcript updates without explicit hops.
@MainActor
final class AIAnalysisService: ObservableObject {

    // MARK: - Public types

    /// Coarse state machine driving the analysis view UI.
    enum AnalysisState: Equatable {
        case idle
        case running
        case completed
        case failed(String)
    }

    /// One entry in the visible transcript shown in `AlertAnalysisView`.
    ///
    /// The transcript is purely a UI projection of the internal
    /// conversation — the model never reads back from it.
    struct TranscriptEntry: Identifiable, Equatable {
        let id: UUID
        let kind: Kind

        enum Kind: Equatable {
            /// A user message — both the initial alert payload and any
            /// follow-up the user types in the chat input. Rendered
            /// uniformly so the conversation reads as a single chat.
            case userMessage(String)
            /// Free-form text returned by the assistant in a non-final turn.
            case assistantText(String)
            /// The assistant requested a Grafana request via the tool.
            case toolCall(method: String, path: String, body: String?)
            /// The Grafana tool call returned. `isError` reflects either
            /// HTTP non-2xx, transport failure, or a malformed argument.
            case toolResult(statusCode: Int?, body: String, isError: Bool)
            /// Service-level informational notice (e.g. iteration cap hit).
            case info(String)
        }
    }

    // MARK: - Published UI state

    /// Ordered transcript suitable for direct rendering. Updated on every
    /// turn boundary.
    @Published private(set) var transcript: [TranscriptEntry] = []

    /// Final Markdown answer from the AI, populated once the loop ends
    /// with a turn that contains no `tool_calls`. Empty while running.
    @Published private(set) var finalAnswer: String = ""

    /// Current high-level state. Views render a spinner while `.running`
    /// and an error banner on `.failed`.
    @Published private(set) var state: AnalysisState = .idle

    // MARK: - Private state

    /// Cap on tool-calling iterations, applied per `start()` invocation.
    /// Prevents a misconfigured prompt from looping the AI indefinitely
    /// (and burning the user's API quota).
    private let maxIterations = 20

    /// Cap on the byte length of any single tool response handed back to
    /// the AI. Grafana query responses can be hundreds of KB which would
    /// blow through the model's context window.
    private let maxToolResponseBytes = 16_384

    /// The active analysis task, if any. Cancellable via `stop()`.
    private var runningTask: Task<Void, Never>?

    /// Conversation kept across turns so a user follow-up via `sendMessage`
    /// can continue from the existing message history rather than starting
    /// over. Reset by `start`.
    private var messages: [Message] = []

    /// Alertmanager and config captured by `start` and reused by
    /// subsequent `sendMessage` invocations. `Alertmanager` is a
    /// `@Model` and isn't `Sendable`; we only access it while
    /// `@MainActor`-isolated, which mirrors how `AlertsManager` handles
    /// the same value.
    private nonisolated(unsafe) var sessionAlertmanager: Alertmanager?
    private var sessionConfig: AIConfig?

    // MARK: - Public API

    /// Starts a fresh analysis. Cancels any in-flight run first, so
    /// repeated taps of "Retry" are safe. Resets transcript, final
    /// answer, and conversation history.
    func start(alert: GettableAlert, alertmanager: Alertmanager, config: AIConfig) {
        runningTask?.cancel()
        transcript = []
        finalAnswer = ""
        messages = []
        sessionAlertmanager = alertmanager
        sessionConfig = config

        let initialPrompt = buildAlertPrompt(alert: alert, alertmanager: alertmanager)
        messages.append(.user(initialPrompt))
        transcript.append(TranscriptEntry(id: UUID(), kind: .userMessage(initialPrompt)))

        launchTask()
    }

    /// Appends a user follow-up message to the existing conversation and
    /// re-enters the tool-calling loop with the new context. No-op if
    /// `start` hasn't been called, the analysis is still running, or the
    /// message is blank.
    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard sessionConfig != nil, sessionAlertmanager != nil else { return }
        guard state != .running else { return }

        messages.append(.user(trimmed))
        transcript.append(TranscriptEntry(id: UUID(), kind: .userMessage(trimmed)))
        // The "final answer" panel is keyed off the most recent turn, so
        // clear it before re-running — otherwise the previous turn's
        // answer stays pinned above the now-stale transcript.
        finalAnswer = ""

        launchTask()
    }

    /// Cancels the current run. Idempotent.
    func stop() {
        runningTask?.cancel()
        runningTask = nil
        if state == .running {
            state = .idle
        }
    }

    /// Spawns the tool-calling loop on a `Task` and maps its outcome to
    /// the published `state`. Shared by `start` and `sendMessage`.
    private func launchTask() {
        state = .running
        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.run()
                if !Task.isCancelled {
                    self.state = .completed
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
        runningTask = task
    }

    // MARK: - Conversation model (provider-neutral)

    /// Provider-neutral block within an assistant message.
    private struct AssistantBlock {
        var text: String?
        var toolUse: ToolUse?

        struct ToolUse {
            let id: String
            let name: String
            /// Raw JSON object string of the tool input. Kept as text so
            /// it can be replayed verbatim into either provider's body.
            let inputJSON: String
        }
    }

    /// Provider-neutral message. `role` mirrors the OpenAI / Anthropic
    /// vocabulary so translation in `buildRequestBody` is a flat switch.
    private struct Message {
        enum Role { case user, assistant, tool }
        let role: Role
        /// Set for user/tool messages. Assistant messages carry `blocks`.
        let text: String
        /// For assistant messages: the parsed text + tool-use blocks.
        let blocks: [AssistantBlock]
        /// For tool messages: which assistant tool-use this resolves.
        let toolUseId: String?
        /// For tool messages: whether the call failed.
        let isError: Bool

        static func user(_ text: String) -> Message {
            Message(role: .user, text: text, blocks: [], toolUseId: nil, isError: false)
        }

        static func assistant(_ blocks: [AssistantBlock]) -> Message {
            Message(role: .assistant, text: "", blocks: blocks, toolUseId: nil, isError: false)
        }

        static func tool(id: String, content: String, isError: Bool) -> Message {
            Message(role: .tool, text: content, blocks: [], toolUseId: id, isError: isError)
        }
    }

    // MARK: - Core loop

    /// The conversation main loop.
    ///
    /// Reads from the persistent `messages` history, alternating between
    /// requesting a completion and executing any requested tool calls,
    /// until the model emits a turn with no tool-use blocks. Used both
    /// for the initial analysis (`start`) and for any follow-up
    /// `sendMessage` turn — the only difference between the two is which
    /// message the caller appended to `messages` before calling.
    private func run() async throws {
        guard let config = sessionConfig else {
            throw AIAnalysisError.invalidConfig
        }
        guard config.isUsable else {
            throw AIAnalysisError.invalidConfig
        }
        guard let endpointURL = URL(string: config.endpoint) else {
            throw AIAnalysisError.invalidConfig
        }
        guard let alertmanager = sessionAlertmanager else {
            throw AIAnalysisError.invalidConfig
        }

        for iteration in 0..<maxIterations {
            try Task.checkCancellation()

            let assistantBlocks = try await requestCompletion(
                endpoint: endpointURL,
                config: config,
                messages: messages
            )

            // Always echo the model's text to the transcript before any
            // tool dispatch so the user can see the reasoning trail.
            for block in assistantBlocks {
                if let text = block.text, !text.isEmpty {
                    transcript.append(TranscriptEntry(id: UUID(), kind: .assistantText(text)))
                }
            }

            messages.append(.assistant(assistantBlocks))

            let toolUses = assistantBlocks.compactMap(\.toolUse)
            if toolUses.isEmpty {
                // Terminal turn — pick the last text block as the final
                // answer. Falls back to a concatenation if multiple text
                // blocks were returned (rare for both providers).
                finalAnswer =
                    assistantBlocks
                    .compactMap(\.text)
                    .joined(separator: "\n\n")
                return
            }

            for toolUse in toolUses {
                try Task.checkCancellation()
                let result = await executeGrafanaTool(
                    inputJSON: toolUse.inputJSON,
                    alertmanager: alertmanager
                )
                transcript.append(
                    TranscriptEntry(
                        id: UUID(),
                        kind: .toolCall(method: result.method, path: result.path, body: result.body)
                    ))
                transcript.append(
                    TranscriptEntry(
                        id: UUID(),
                        kind: .toolResult(
                            statusCode: result.statusCode,
                            body: result.responseText,
                            isError: result.isError
                        )
                    ))
                messages.append(
                    .tool(
                        id: toolUse.id,
                        content: result.responseText,
                        isError: result.isError
                    ))
            }

            if iteration == maxIterations - 1 {
                transcript.append(
                    TranscriptEntry(
                        id: UUID(),
                        kind: .info("Reached tool-call iteration cap (\(maxIterations)); stopping.")
                    ))
            }
        }
    }

    // MARK: - Prompt building

    /// Renders the alert in a stable, prompt-friendly format.
    ///
    /// Keeps the structure flat enough that the AI can pattern-match
    /// label keys (`namespace`, `pod`, `instance`) without parsing
    /// nested JSON. The alertmanager base URL is included so the AI knows
    /// where its `grafana_request` calls will be sent.
    ///
    /// Conventions:
    /// - `summary` / `description` annotations are pulled up into their
    ///   own sections — they're usually long-form Markdown and would
    ///   otherwise get lost inside a bulleted Annotations list when
    ///   their value contains newlines.
    /// - All labels are emitted unfiltered, including Grafana-internal
    ///   `__…__` keys (`__alert_rule_uid__`, `__dashboardUid__`, …) so
    ///   the AI can correlate the alert to its rule / dashboard via
    ///   `grafana_request`.
    /// - Remaining multi-line annotation values are wrapped in fenced
    ///   code blocks so newlines don't confuse the surrounding list.
    private func buildAlertPrompt(alert: GettableAlert, alertmanager: Alertmanager) -> String {
        var lines: [String] = []
        lines.append("# Alert to analyze")
        lines.append("")
        // Emit the alert metadata as a Markdown bullet list so the
        // transcript renderer keeps each field on its own line. Plain
        // consecutive lines would otherwise be collapsed into a single
        // paragraph via Markdown soft line breaks.
        lines.append("- Grafana Base URL: `\(alertmanager.url)`")
        if let source = alert.grafanaAlertmanagerSource {
            lines.append("- Grafana Alertmanager Source: `\(source)`")
        }
        lines.append("- Alertname: `\(alert.alertName)`")
        lines.append("- Severity: `\(alert.severity)`")
        lines.append("- State: `\(alert.status.state.rawValue)`")
        lines.append("- Started At: \(alert.startsAt.formatted(.iso8601))")
        lines.append("- Last Updated: \(alert.updatedAt.formatted(.iso8601))")

        if let summary = alert.summary, !summary.isEmpty {
            lines.append("")
            lines.append("## Summary")
            lines.append(summary)
        }

        if let description = alert.description, !description.isEmpty {
            lines.append("")
            lines.append("## Description")
            lines.append(description)
        }

        lines.append("")
        lines.append("## Labels")
        for (key, value) in alert.labels.sorted(by: { $0.key < $1.key }) {
            lines.append("- `\(key)` = `\(value)`")
        }

        let remainingAnnotations = alert.annotations
            .filter { $0.key != "summary" && $0.key != "description" }
            .sorted(by: { $0.key < $1.key })
        if !remainingAnnotations.isEmpty {
            lines.append("")
            lines.append("## Annotations")
            for (key, value) in remainingAnnotations {
                lines.append("- `\(key)` = `\(value)`")
            }
        }

        lines.append("")
        lines.append("Investigate using `grafana_request` and produce the final analysis.")
        return lines.joined(separator: "\n")
    }

    // MARK: - AI request dispatch

    /// Sends one round of the conversation to the configured AI endpoint
    /// and parses the assistant response into provider-neutral blocks.
    private func requestCompletion(
        endpoint: URL,
        config: AIConfig,
        messages: [Message]
    ) async throws -> [AssistantBlock] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try buildRequestBody(config: config, messages: messages)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIAnalysisError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw AIAnalysisError.httpError(status: http.statusCode, body: body)
        }

        return try parseResponse(data: data)
    }

    /// Builds the OpenAI-format Chat Completions request body.
    ///
    /// `messages` is an array with `tool_calls` on assistant messages and
    /// `role:"tool"` for results, plus a top-level `tools` array describing
    /// `grafana_request`. Vendors with an OpenAI-compatible endpoint
    /// (Anthropic, Gemini, Azure, Ollama, …) accept this shape directly.
    private func buildRequestBody(config: AIConfig, messages: [Message]) throws -> Data {
        var openAIMessages: [[String: Any]] = []
        openAIMessages.append([
            "role": "system",
            "content": config.systemPrompt,
        ])

        for message in messages {
            switch message.role {
            case .user:
                openAIMessages.append([
                    "role": "user",
                    "content": message.text,
                ])
            case .assistant:
                var entry: [String: Any] = ["role": "assistant"]
                let textParts = message.blocks.compactMap(\.text).filter { !$0.isEmpty }
                // OpenAI requires `content` to be present (string or null).
                entry["content"] = textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n")
                let toolUses = message.blocks.compactMap(\.toolUse)
                if !toolUses.isEmpty {
                    entry["tool_calls"] = toolUses.map { use in
                        [
                            "id": use.id,
                            "type": "function",
                            "function": [
                                "name": use.name,
                                // OpenAI expects `arguments` to be a JSON
                                // *string*, not an object.
                                "arguments": use.inputJSON,
                            ],
                        ]
                    }
                }
                openAIMessages.append(entry)
            case .tool:
                openAIMessages.append([
                    "role": "tool",
                    "tool_call_id": message.toolUseId ?? "",
                    "content": message.text,
                ])
            }
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": openAIMessages,
            "tools": [toolDefinition],
        ]

        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// Parses an OpenAI Chat Completions response body into
    /// provider-neutral assistant blocks. Unknown / unexpected shapes are
    /// surfaced as `AIAnalysisError.malformedResponse`.
    private func parseResponse(data: Data) throws -> [AssistantBlock] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAnalysisError.malformedResponse
        }
        guard let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw AIAnalysisError.malformedResponse
        }

        var blocks: [AssistantBlock] = []
        if let content = message["content"] as? String, !content.isEmpty {
            blocks.append(AssistantBlock(text: content, toolUse: nil))
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let id = call["id"] as? String,
                    let fn = call["function"] as? [String: Any],
                    let name = fn["name"] as? String,
                    let arguments = fn["arguments"] as? String
                else { continue }
                blocks.append(
                    AssistantBlock(
                        text: nil,
                        toolUse: AssistantBlock.ToolUse(id: id, name: name, inputJSON: arguments)
                    ))
            }
        }
        return blocks
    }

    // MARK: - Tool execution

    /// Result of a single `grafana_request` tool invocation. The
    /// transcript stores it for display; the loop stores `responseText`
    /// back in the conversation for the AI to read.
    private struct GrafanaToolResult {
        let method: String
        let path: String
        let body: String?
        let statusCode: Int?
        let responseText: String
        let isError: Bool
    }

    /// Parses the AI-supplied tool input and executes the proxied request.
    ///
    /// Validation:
    /// - `method` defaults to `GET`; only `GET` and `POST` are accepted.
    /// - `path` must start with `/` (we always join it to the alertmanager
    ///   base URL — absolute URLs are rejected so the AI can't redirect
    ///   the request to a different host).
    ///
    /// Failures are surfaced through the returned struct rather than
    /// thrown, so a bad tool call shows up as a tool_result with
    /// `is_error: true` and the AI can recover.
    private func executeGrafanaTool(
        inputJSON: String,
        alertmanager: Alertmanager
    ) async -> GrafanaToolResult {
        let parsed =
            (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let method = (parsed["method"] as? String ?? "GET").uppercased()
        let rawPath = parsed["path"] as? String ?? ""
        // `body` is allowed to be either a JSON object or a JSON string —
        // models sometimes inline an object directly, sometimes stringify
        // it inside the function arguments. Accept both.
        let bodyString: String?
        if let bodyDict = parsed["body"] as? [String: Any] {
            bodyString = (try? JSONSerialization.data(withJSONObject: bodyDict, options: []))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else if let bodyStr = parsed["body"] as? String, !bodyStr.isEmpty {
            bodyString = bodyStr
        } else {
            bodyString = nil
        }

        guard method == "GET" || method == "POST" else {
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: nil,
                responseText: "Tool error: only GET and POST are supported.",
                isError: true
            )
        }

        guard rawPath.hasPrefix("/") else {
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: nil,
                responseText: "Tool error: `path` must start with `/` (got \(rawPath)).",
                isError: true
            )
        }

        let urlString = alertmanager.url + rawPath
        guard let url = URL(string: urlString) else {
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: nil,
                responseText: "Tool error: could not form URL from base + path.",
                isError: true
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "POST", let bodyString = bodyString {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(bodyString.utf8)
        }

        do {
            let service = AlertmanagerService()
            try await service.configureRequestAuthentication(&request, for: alertmanager)
        } catch {
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: nil,
                responseText: "Tool error: failed to apply auth: \(error.localizedDescription)",
                isError: true
            )
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary response>"
            let truncated = truncate(bodyText, to: maxToolResponseBytes)
            let isError = !(200...299).contains(status)
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: status,
                responseText: truncated,
                isError: isError
            )
        } catch {
            return GrafanaToolResult(
                method: method, path: rawPath, body: bodyString,
                statusCode: nil,
                responseText: "Tool error: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    /// Truncates a tool response to `limit` bytes, appending a marker so
    /// the AI knows the body was cut and can adjust queries to be narrower.
    private func truncate(_ text: String, to limit: Int) -> String {
        let data = Data(text.utf8)
        if data.count <= limit { return text }
        let head = data.prefix(limit)
        let prefix = String(data: head, encoding: .utf8) ?? text
        return prefix + "\n\n[…response truncated at \(limit) bytes…]"
    }

    // MARK: - Tool schema

    /// OpenAI Chat Completions `tools[]` entry for `grafana_request`.
    private var toolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "grafana_request",
                "description":
                    "Perform an authenticated HTTP request against the Grafana instance the alert originated from. Use this to query datasources, dashboards, and the alerting API.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "method": [
                            "type": "string",
                            "enum": ["GET", "POST"],
                            "description": "HTTP method; only GET and POST are allowed.",
                        ],
                        "path": [
                            "type": "string",
                            "description":
                                "Path on the Grafana server, starting with `/` (e.g. `/api/datasources`).",
                        ],
                        "body": [
                            "type": ["object", "string"],
                            "description":
                                "Optional JSON body for POST requests. Either a JSON object or a stringified JSON object.",
                        ],
                    ],
                    "required": ["method", "path"],
                ],
            ],
        ]
    }
}

/// Errors surfaced by `AIAnalysisService`. Conforms to `LocalizedError` so
/// `errorDescription` is directly displayable in the analysis view.
enum AIAnalysisError: LocalizedError {
    /// The user's AI config is missing required fields (key/endpoint/model).
    case invalidConfig
    /// The AI endpoint returned a non-2xx status.
    case httpError(status: Int, body: String)
    /// Transport-level failure (DNS, TLS, no response object).
    case networkError(String)
    /// The response body wasn't recognised as the expected provider shape.
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "AI is not configured. Open Settings → AI to add an endpoint, key, and model."
        case .httpError(let status, let body):
            return "AI request failed with HTTP \(status): \(body)"
        case .networkError(let detail):
            return "AI request failed: \(detail)"
        case .malformedResponse:
            return "AI returned a response in an unexpected format."
        }
    }
}
