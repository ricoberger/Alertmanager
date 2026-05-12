//
//  MarkdownView.swift
//  Alertmanager
//

import SwiftUI

/// Lightweight block-level Markdown renderer used by `AlertAnalysisView`.
///
/// SwiftUI's `Text(.init(markdownString))` only interprets *inline* Markdown
/// (bold, italic, code spans, links). The AI's final answer mixes inline
/// markup with headers, bullet/numbered lists, blockquotes, and fenced code
/// blocks — those need block-level rendering, which this view provides.
///
/// The parser is intentionally small and forgiving: it covers the subset of
/// CommonMark that the default system prompt asks the model to produce.
/// Anything not recognised as a block-level construct falls through as a
/// paragraph, with inline Markdown still resolved via `AttributedString`.
struct MarkdownView: View {
    /// The raw Markdown text to render.
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Block model

    /// Coarse structural units the renderer knows how to display.
    /// Unrecognised input degrades to `.paragraph` with inline Markdown.
    private enum Block {
        case header(level: Int, text: String)
        case paragraph(String)
        case bulletList([String])
        case numberedList([String])
        case quote(String)
        case codeBlock(String)
        case horizontalRule
    }

    // MARK: - Parsing

    /// Splits `source` into a flat list of blocks.
    ///
    /// The parser walks lines top-to-bottom; each loop iteration consumes
    /// as many lines as belong to the current block. Blank lines are
    /// block separators. Continuation lines without a list marker are
    /// folded into the previous list item.
    private func parseBlocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block — gobble until the matching closing fence.
            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }  // consume closing fence
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            if let header = parseHeader(trimmed) {
                blocks.append(header)
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteParts: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    let stripped = String(t.drop(while: { $0 == ">" }))
                        .trimmingCharacters(in: .whitespaces)
                    quoteParts.append(stripped)
                    i += 1
                }
                blocks.append(.quote(quoteParts.joined(separator: " ")))
                continue
            }

            if isBulletLine(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if isBulletLine(t) {
                        items.append(bulletContent(t))
                    } else if !items.isEmpty {
                        // Treat unmarked continuation lines as belonging to
                        // the previous bullet (common when the AI wraps
                        // long bullet items).
                        items[items.count - 1] += " " + t
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if isNumberedLine(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if isNumberedLine(t) {
                        items.append(numberedContent(t))
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + t
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Paragraph: collect contiguous non-special lines until a blank
            // line or the start of another block-level construct.
            var paragraphLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty
                    || parseHeader(t) != nil
                    || isBulletLine(t)
                    || isNumberedLine(t)
                    || t.hasPrefix(">")
                    || t.hasPrefix("```")
                {
                    break
                }
                paragraphLines.append(t)
                i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    /// Returns a `.header` block if `line` starts with one to six `#`
    /// characters followed by a space, otherwise `nil`.
    private func parseHeader(_ line: String) -> Block? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return .header(level: level, text: String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// `true` if the line opens a bullet list item (`-`, `*`, or `+`).
    private func isBulletLine(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// Strips the bullet marker and following space from a bullet line.
    private func bulletContent(_ line: String) -> String {
        String(line.dropFirst(2))
    }

    /// `true` if the line opens a numbered list item (`<digits>. <text>`).
    private func isNumberedLine(_ line: String) -> Bool {
        var sawDigit = false
        for char in line {
            if char.isNumber {
                sawDigit = true
            } else if char == "." && sawDigit {
                // Need ". " (dot + space) to be a list marker, not just a
                // sentence ending with a number.
                let rest = line.drop(while: { $0.isNumber })
                return rest.hasPrefix(". ")
            } else {
                return false
            }
        }
        return false
    }

    /// Strips the numeric marker and following space from a numbered line.
    private func numberedContent(_ line: String) -> String {
        guard let dotIdx = line.firstIndex(of: ".") else { return line }
        let after = line.index(after: dotIdx)
        guard after < line.endIndex else { return "" }
        return String(line[line.index(after: after)...])
    }

    // MARK: - Rendering

    /// Maps a parsed block to its SwiftUI representation.
    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .header(let level, let text):
            inlineText(text)
                .font(headerFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundColor(.secondary)
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                        inlineText(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .codeBlock(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))

        case .horizontalRule:
            Divider()
        }
    }

    /// Parses inline Markdown (`**bold**`, `*italic*`, `` `code` ``, links)
    /// into a `Text` view, falling back to the raw string on parse failure.
    private func inlineText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(markdown)
    }

    /// Header-level → SwiftUI font mapping. Levels 4+ collapse onto
    /// `.headline` since the AI rarely emits anything past `###`.
    private func headerFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}

#Preview {
    ScrollView {
        MarkdownView(text: """
            # Analysis

            ## Summary

            The `api-server` pod in `production` is restarting with **OOMKilled** every 4 minutes.

            ## Evidence

            - Memory usage exceeded 90% in the last 30 minutes (`container_memory_working_set_bytes`).
            - Loki logs show `out of memory: kill process` from the kernel.
            - The dashboard *api-server* panel "Memory" has been red since 09:42.

            ## Likely cause

            A recent deploy raised the request rate without a matching memory limit increase.

            ## Suggested next steps

            1. Roll back to the previous deployment.
            2. Increase the memory limit in the `Deployment` spec.
            3. Add an `HPA` keyed on memory utilization.
            """)
        .padding()
    }
}
