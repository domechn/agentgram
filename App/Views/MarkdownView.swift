import SwiftUI
import AgentCore

func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
}

/// Renders parsed blocks. Blocks are identified by position, so while a message streams only the
/// last block changes and the views above it (with their expanded state) are reused.
struct MarkdownView: View {
    let blocks: [MDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(inlineMarkdown(text)).textSelection(.enabled)
                case .heading(let level, let text):
                    Text(inlineMarkdown(text))
                        .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline).fontWeight(.semibold)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .quote(let text, let collapsible):
                    QuoteBlock(text: text, collapsible: collapsible)
                case .table(let header, let rows):
                    TableBlock(header: header, rows: rows)
                case .rule:
                    Divider()
                }
            }
        }
    }
}

/// Code and tool output: copy button, and long blocks start collapsed.
struct CodeBlock: View {
    let language: String
    let text: String
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > 16
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(language.isEmpty ? "code" : language).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if long {
                    Button(expanded ? "Collapse" : "Show all \(lines.count) lines") { expanded.toggle() }
                }
                Button {
                    Pasteboard.copy(text)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .buttonStyle(.borderless).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(long && !expanded ? lines.prefix(12).joined(separator: "\n") : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct QuoteBlock: View {
    let text: String
    let collapsible: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(inlineMarkdown(text))
                    .lineLimit(collapsible && !expanded ? 3 : nil)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if collapsible {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell)).fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inlineMarkdown(cell))
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(8)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
