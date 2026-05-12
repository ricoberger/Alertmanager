//
//  AIConfig.swift
//  Alertmanager
//

import Foundation

/// User-configured AI backend settings used by `AIAnalysisService` to
/// analyze a Grafana alert.
///
/// Persisted as a single JSON blob in `UserDefaults` (`SettingsManager.aiConfig`).
/// The value is intentionally simple — one endpoint, one model, one key —
/// so users can point the feature at any OpenAI-compatible endpoint they
/// have access to without configuring multiple profiles. Most modern AI
/// vendors (OpenAI itself, Anthropic, Google's Gemini, Azure OpenAI,
/// Ollama, vLLM, …) expose an OpenAI-compatible `/chat/completions`
/// endpoint, so a single wire format is enough.
///
/// The `systemPrompt` is what gives the AI its instructions: it should
/// describe the available Grafana datasources, recommended query shapes,
/// and the request bodies needed to fetch logs / metrics / dashboards via
/// the Grafana HTTP API. The service exposes a `grafana_request` tool that
/// the AI can invoke to perform any GET/POST against the alert's Grafana
/// base URL.
struct AIConfig: Codable, Equatable, Hashable, Sendable {
    /// Master toggle for the AI analysis feature. When `false`, the
    /// per-alert "Analyze" button is hidden everywhere. Defaults to
    /// `false` so the feature is strictly opt-in — users with no API key
    /// configured don't see a button they can't use.
    var enabled: Bool
    /// Full URL of the completion endpoint (not just a base — the request
    /// is POSTed to this URL verbatim).
    var endpoint: String
    /// API key sent in the `Authorization: Bearer …` header. Stored
    /// plaintext in `UserDefaults`, matching the project's existing token
    /// storage.
    var apiKey: String
    /// Model identifier (e.g. `gpt-4o`, `claude-sonnet-4-5`, `gemini-2.5-pro`).
    var model: String
    /// Free-form system prompt that defines the AI's behaviour, including
    /// which Grafana datasources are available and how to query them.
    var systemPrompt: String

    /// Empty config seeded into `SettingsManager` on first launch.
    ///
    /// No endpoint, model, or system prompt is suggested by default —
    /// pointing the feature at a vendor inherently couples it to that
    /// vendor's URL/model naming, and seeding a default prompt biases the
    /// AI toward an SRE-flavoured workflow that may not match the user's
    /// setup. Users fill these in explicitly.
    static let `default` = AIConfig(
        enabled: false,
        endpoint: "",
        apiKey: "",
        model: "",
        systemPrompt: ""
    )

    /// Whether the config has the minimum fields filled in to run an
    /// analysis. Used by the "Analyze" button to surface a clear error
    /// instead of issuing a misconfigured request.
    var isUsable: Bool {
        !endpoint.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    /// Custom decoder so existing on-disk configs (saved before `enabled`
    /// was added) decode cleanly — the missing key falls back to `false`
    /// instead of failing the whole config and wiping the user's endpoint,
    /// key, model, and system prompt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        endpoint = try container.decode(String.self, forKey: .endpoint)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        model = try container.decode(String.self, forKey: .model)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    }

    /// Memberwise initializer retained for `AIConfig.default` and tests;
    /// the synthesized one is shadowed by the custom decoder above.
    init(enabled: Bool, endpoint: String, apiKey: String, model: String, systemPrompt: String) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
    }
}
