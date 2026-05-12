//
//  AlertAnalysisView.swift
//  Alertmanager
//

import SwiftData
import SwiftUI

/// Value used to drive the per-alert analysis window.
///
/// `WindowGroup(for:)` requires a `Hashable & Codable` value for state
/// restoration, so we pass the minimum needed to look the alert back up:
/// the alertmanager's stable id (resolved against SwiftData) and the
/// alert's fingerprint (resolved against `AlertsManager.shared`).
struct AlertAnalysisContext: Codable, Hashable {
    /// The alertmanager that produced the alert.
    let alertmanagerID: UUID
    /// The alert's fingerprint — stable across polls.
    let fingerprint: String
}

/// Window contents rendered for the per-alert "Analyze" action.
///
/// Resolves the alert + alertmanager from the supplied `AlertAnalysisContext`,
/// owns a long-lived `AIAnalysisService` instance, and renders:
/// - A header summarising the alert.
/// - A scrollable transcript of the AI's reasoning + each Grafana tool
///   call and response.
/// - A "final answer" panel populated when the loop terminates.
/// - Stop / Retry toolbar buttons.
struct AlertAnalysisView: View {
    /// The context value passed to `openWindow(id:value:)`.
    let context: AlertAnalysisContext

    /// All alertmanagers — used to resolve the one referenced by
    /// `context.alertmanagerID`.
    @Query private var alertmanagers: [Alertmanager]

    /// Service driving the AI tool-call loop. `@StateObject` so its
    /// lifetime is the window's, not any individual sub-view's.
    @StateObject private var service = AIAnalysisService()

    /// Settings (for the AI config + system prompt).
    @StateObject private var settings = SettingsManager.shared

    /// `true` once the initial analysis has been kicked off, so the
    /// `onAppear` doesn't trigger a re-run when SwiftUI re-creates the
    /// view body during the window lifecycle.
    @State private var hasStarted = false

    /// Working buffer for the bottom-of-window chat input. Cleared after
    /// the message is sent. Bound to the multi-line follow-up `TextField`.
    @State private var userInput: String = ""

    /// Identifier of the invisible bottom-of-transcript sentinel view
    /// used as the auto-scroll target. Kept as a constant so the
    /// `ScrollViewReader` placement and `.onChange` handler can't drift
    /// out of sync.
    private let scrollBottomID = "transcript-bottom"

    /// Snapshot of the alert + alertmanager captured on the first
    /// successful resolution. Held in `@State` so the analysis window
    /// keeps rendering even after the alert resolves on the backend and
    /// drops out of `AlertsManager`'s cache mid-analysis.
    ///
    /// `GettableAlert` is a value type so the snapshot is genuinely
    /// detached from the cache. The `Alertmanager` reference is a
    /// SwiftData `@Model`; holding it keeps the instance alive in memory
    /// for the lifetime of the window even if the user later deletes it
    /// from the sidebar — without that we'd lose the auth + base URL the
    /// service needs for `grafana_request`.
    @State private var snapshot: AlertSnapshot?

    /// Captured pair of `alert` + `alertmanager` used by `AlertAnalysisView`
    /// for the lifetime of the window.
    private struct AlertSnapshot {
        let alert: GettableAlert
        let alertmanager: Alertmanager
    }

    var body: some View {
        Group {
            if let snapshot = snapshot {
                content(alert: snapshot.alert, alertmanager: snapshot.alertmanager)
            } else {
                ContentUnavailableView(
                    "Alert Not Found",
                    systemImage: "bell.slash",
                    description: Text(
                        "The alert could not be found. It may have already been resolved or expired."
                    )
                )
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .navigationTitle("Analyze Alert")
        .onAppear { captureSnapshotIfNeeded() }
        // Cold-launch case: the alert cache may not be populated yet
        // when the window first appears (notification tap, etc.).
        // Retry capture on every fetch until we've snapshotted once.
        .onReceive(NotificationCenter.default.publisher(for: .alertsDidUpdate)) { _ in
            captureSnapshotIfNeeded()
        }
    }

    // MARK: - Resolution

    /// Look up the live alert + alertmanager from the SwiftData query
    /// and the `AlertsManager` cache. Used only as the source of the
    /// one-shot snapshot captured by `captureSnapshotIfNeeded`.
    private var liveLookup: (alert: GettableAlert, alertmanager: Alertmanager)? {
        guard let alertmanager = alertmanagers.first(where: { $0.id == context.alertmanagerID })
        else {
            return nil
        }
        guard
            let alert = AlertsManager.shared.alertsByAlertmanager[context.alertmanagerID]?
                .first(where: { $0.fingerprint == context.fingerprint })
        else {
            return nil
        }
        return (alert, alertmanager)
    }

    /// Captures `snapshot` from `liveLookup` if we haven't already.
    /// Idempotent — once a snapshot exists it is never re-resolved, so
    /// the alert disappearing from the cache later does not invalidate
    /// the window.
    private func captureSnapshotIfNeeded() {
        guard snapshot == nil, let live = liveLookup else { return }
        snapshot = AlertSnapshot(alert: live.alert, alertmanager: live.alertmanager)
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(alert: GettableAlert, alertmanager: Alertmanager) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(alert: alert, alertmanager: alertmanager)
                .padding()
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // `ScrollViewReader` lets us programmatically scroll the
            // transcript to the latest entry whenever a new turn lands —
            // the alternative `defaultScrollAnchor(.bottom)` keeps the
            // viewport pinned to the bottom even when the user has
            // scrolled up to read an earlier turn, which is the wrong
            // UX for a transcript that mixes long AI responses with
            // user follow-ups.
            //
            // The scroll target is a zero-height sentinel view pinned at
            // the absolute bottom of the scrollable content (below the
            // transcript's trailing padding). Scrolling to the last
            // message's id with `.bottom` anchor would otherwise stop a
            // few pixels above the true bottom — the trailing padding
            // would remain reachable by further scrolling.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        transcriptSection
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id(scrollBottomID)
                    }
                }
                .onChange(of: service.transcript.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(scrollBottomID, anchor: .bottom)
                    }
                }
            }

            Divider()
            chatInput
        }
        .toolbar {
            ToolbarItemGroup {
                if service.state == .running {
                    Button(action: service.stop) {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Cancel the in-flight analysis.")
                }
                Button(action: { restart(alert: alert, alertmanager: alertmanager) }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .disabled(service.state == .running)
                .help("Discard the current transcript and re-run the analysis.")
            }
        }
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            service.start(alert: alert, alertmanager: alertmanager, config: settings.aiConfig)
        }
    }

    // MARK: - Header

    /// Top-of-window summary, laid out to mirror `AlertRowView`'s
    /// collapsed header exactly: a left-aligned title + summary stack
    /// next to a right-aligned row of time / severity / user-defined
    /// label badges. The analysis status is rendered in the window
    /// toolbar — see `statusToolbarItem` — so this view stays a 1:1
    /// match for the alert row.
    private func header(alert: GettableAlert, alertmanager: Alertmanager) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle(alert: alert, alertmanager: alertmanager))
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = alert.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                timeBadge(for: alert)
                severityBadge(for: alert)
                ForEach(customLabelBadges(for: alert), id: \.0) { _, value, color in
                    Text(value.uppercased())
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color)
                        .cornerRadius(4)
                }
            }
        }
    }

    /// Title shown on row 1 of the header.
    ///
    /// Mirrors `AlertRowView`: when `showAlertmanagerName` is enabled the
    /// alertmanager's display name is prefixed in brackets so the user
    /// can tell at a glance which backend the alert came from.
    private func headerTitle(alert: GettableAlert, alertmanager: Alertmanager) -> String {
        let displayName = alertmanagerDisplayName(for: alertmanager)
        return settings.showAlertmanagerName
            ? "[\(displayName)] \(alert.alertName)"
            : alert.alertName
    }

    /// Display name fallback chain (configured name → URL host → URL),
    /// matching `AlertRowView.alertmanagerDisplayName`.
    private func alertmanagerDisplayName(for alertmanager: Alertmanager) -> String {
        if !alertmanager.name.isEmpty { return alertmanager.name }
        if let url = URL(string: alertmanager.url), let host = url.host { return host }
        return alertmanager.url
    }

    /// Relative-time pill ("2m ago", etc.), styled identically to the row.
    private func timeBadge(for alert: GettableAlert) -> some View {
        Text(relativeTime(from: alert.startsAt))
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray)
            .cornerRadius(4)
    }

    /// Color-coded severity pill, styled identically to the row.
    private func severityBadge(for alert: GettableAlert) -> some View {
        Text(alert.severity.uppercased())
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(severityColor(alert.severity))
            .cornerRadius(4)
    }

    /// User-configured label badges (key/value/color tuples), resolved
    /// from `SettingsManager.labelBadgeConfigs` and shown in the header
    /// just like `AlertRowView` does.
    private func customLabelBadges(for alert: GettableAlert) -> [(String, String, Color)] {
        settings.labelBadgeConfigs.compactMap { config in
            guard !config.labelKey.isEmpty,
                let value = alert.labels[config.labelKey]
            else { return nil }
            return (config.labelKey, value, config.color)
        }
    }

    /// Formats `date` as a localized abbreviated relative string
    /// (e.g. "5m ago"). Mirrors `AlertRowView.relativeTime`.
    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Small status subtitle shown beneath the chat input.
    ///
    /// Replaces the old toolbar status indicator: a single secondary-
    /// styled row that calls out the current analysis state with an
    /// icon and a short label ("Analyzing…", "Done", "Failed").
    /// Hidden in the `.idle` state — there's nothing meaningful to say
    /// before `start` has been called.
    @ViewBuilder
    private var statusSubtitle: some View {
        switch service.state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Analyzing…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let reason):
            // Icon + text both red so the failure state reads as a
            // single unit, the way `.completed` reads as fully green.
            // First letter is upper-cased because URL/network errors
            // from Apple's localisations arrive lowercase (e.g.
            // `cancelled`), which looks odd as a status label.
            Label {
                Text(sentenceCased(reason))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(reason)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    /// Returns `text` with the first character upper-cased and the rest
    /// untouched. Used to normalise short status messages like
    /// "cancelled" into "Cancelled" without disturbing acronyms or
    /// proper nouns later in the string.
    private func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Sections

    /// Scrollable list of every transcript entry, in order. The
    /// terminal assistant message in the transcript is the final
    /// analysis answer, so there is no separate summary panel — and
    /// failures surface through the status subtitle below the chat
    /// input rather than an inline error banner.
    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(service.transcript) { entry in
                transcriptRow(entry)
            }

            if service.state == .running && service.transcript.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Sending alert to AI…").font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Render a single transcript entry. Style hints (icon + tint) make
    /// the tool-call / response / text turns visually distinguishable.
    @ViewBuilder
    private func transcriptRow(_ entry: AIAnalysisService.TranscriptEntry) -> some View {
        switch entry.kind {
        case .userMessage(let text):
            // User follow-up sent via the chat input. Rendered as a
            // right-aligned chat bubble using the same `MarkdownView`
            // as assistant turns so block-level markup (headers, lists,
            // code blocks in the initial alert prompt) renders the
            // same way on both sides of the conversation.
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 40)
                MarkdownView(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }

        case .assistantText(let text):
            // Mirror of `.userMessage` flipped to the left side: sparkles
            // icon leads, then the bubble, then a trailing `Spacer` to
            // keep the bubble from stretching across the full row. Gives
            // the transcript a classic chat layout (user right, AI left).
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                MarkdownView(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 40)
            }

        case .toolCall(let method, let path, let body):
            // Same disclosure-group style as `.toolResult`. The expand
            // arrow is rendered even for bodiless requests (GETs) so the
            // tool-call label lines up horizontally with the tool-result
            // label below it — without that, GET requests would sit a
            // few points to the left and break the visual alignment.
            DisclosureGroup {
                if let body = body, !body.isEmpty {
                    Text(body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("(no request body)")
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } label: {
                toolCallLabel(method: method, path: path)
            }

        case .toolResult(let statusCode, let body, let isError):
            DisclosureGroup {
                Text(body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "xmark.octagon" : "arrow.down.left.circle")
                        .foregroundColor(isError ? .red : .green)
                    Text(statusCode.map { "HTTP \($0)" } ?? "No response")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        case .info(let text):
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.orange)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Shared label used in the `.toolCall` transcript row — both as the
    /// `DisclosureGroup` label when a body is present, and as the bare
    /// inline label when not. Styled to match the `.toolResult` label
    /// (caption + secondary) so request and response sit visually
    /// adjacent in the transcript.
    private func toolCallLabel(method: String, path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.circle")
                .foregroundColor(.blue)
            Text("\(method) \(path)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Chat input

    /// Bottom-of-window follow-up message composer.
    ///
    /// Sits below the transcript and lets the user push a free-form
    /// follow-up question into the same conversation (the AI keeps its
    /// `grafana_request` tool, so it can issue further queries if
    /// needed). Disabled while the loop is running so user messages
    /// can't queue up mid-turn and confuse the model's ordering.
    ///
    /// Input behaviour: ↩ submits the message; ⇧↩ inserts a newline.
    /// The field auto-grows up to three lines and starts scrolling
    /// internally beyond that, so a long paste doesn't blow up the
    /// window chrome.
    private var chatInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            chatInputRow
            statusSubtitle
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// The TextField + send button row, factored out of `chatInput` so
    /// the status subtitle can sit underneath without re-nesting another
    /// container with its own padding/background.
    private var chatInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a follow-up question…", text: $userInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .disabled(service.state == .running)
                // Plain Return submits; Shift+Return inserts a newline.
                //
                // `.onKeyPress` consumes the Return event regardless of
                // the result returned, so the TextField never gets its
                // default newline-on-Return behaviour back via `.ignored`.
                // We append "\n" manually for the Shift+Return case. The
                // insertion lands at the end of the buffer (we can't read
                // the TextField's selection from SwiftUI), which is fine
                // for short follow-up messages — long composes are rare.
                .onKeyPress { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        userInput += "\n"
                        return .handled
                    }
                    if canSendMessage {
                        sendChatMessage()
                    }
                    return .handled
                }
                .accessibilityIdentifier("analyze-chat-input")

            Button(action: sendChatMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(canSendMessage ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessage)
            .help("Send (↩) — Shift+↩ for newline")
            // Match the TextField's bottom padding so the icon sits at
            // the same visual baseline as the last line of text, both
            // when the field is single-line and when it has expanded.
            .padding(.bottom, 6)
        }
    }

    /// True only when the chat input has non-whitespace content and the
    /// loop isn't currently running. Drives both the send button's
    /// `disabled` state and its tint.
    private var canSendMessage: Bool {
        !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && service.state != .running
    }

    // MARK: - Actions

    /// Restart the analysis. Matches the `Retry` toolbar button.
    private func restart(alert: GettableAlert, alertmanager: Alertmanager) {
        service.start(alert: alert, alertmanager: alertmanager, config: settings.aiConfig)
    }

    /// Push the current chat-input buffer into the conversation and
    /// reset the buffer. The service guards against empty/duplicate
    /// sends, so a quick second tap while the AI is still spinning up is
    /// a no-op.
    private func sendChatMessage() {
        let text = userInput
        userInput = ""
        service.sendMessage(text)
    }

    /// Maps a severity label to its display color, mirroring `AlertRowView`.
    private func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical": return .purple
        case "error": return .red
        case "warning": return .orange
        case "info": return .blue
        default: return .gray
        }
    }
}
