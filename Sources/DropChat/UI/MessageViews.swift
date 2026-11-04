import AppKit
import DropChatCore
import DroppyKit
import SwiftUI

/// Renders Markdown: fenced code blocks as monospaced cards, everything else
/// through `AttributedString`'s inline Markdown.
struct MarkdownText: View {
    let text: String
    @Environment(\.chatTheme) private var theme

    enum Block: Hashable {
        case prose(String)
        case code(language: String, body: String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, body: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    if !prose.isEmpty { blocks.append(.prose(prose.joined(separator: "\n"))) }
                    prose = []
                    language = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        if let lines = code { blocks.append(.code(language: language, body: lines.joined(separator: "\n"))) }
        if !prose.isEmpty { blocks.append(.prose(prose.joined(separator: "\n"))) }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    let trimmed = prose.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        Text(Self.attributed(trimmed))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @Environment(\.chatTheme) private var theme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Copy code")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.primary)
                    .textSelection(.enabled)
                    .fixedSize()
            }
        }
        .padding(DroppySpacing.sm)
        .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let results: [String: ToolResult]
    let runningToolIDs: Set<String>
    @Environment(\.chatTheme) private var theme

    var body: some View {
        if message.role == .user {
            userBody
        } else {
            assistantBody
        }
    }

    private var userBody: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: DroppySpacing.xs) {
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text):
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.primary)
                            .textSelection(.enabled)
                            .padding(.horizontal, DroppySpacing.smd)
                            .padding(.vertical, DroppySpacing.xsm)
                            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
                    case .image:
                        AttachmentPill(name: "Image", systemImage: "photo")
                    case .document(let document):
                        AttachmentPill(name: document.filename, systemImage: document.data == nil ? "doc.text" : "doc.richtext")
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text) where !text.isEmpty:
                    MarkdownText(text: text)
                case .reasoning(let reasoning) where !reasoning.text.isEmpty:
                    ReasoningDisclosure(text: reasoning.text, isLive: false)
                case .toolCall(let call):
                    ToolCallChip(call: call, result: results[call.id], isRunning: runningToolIDs.contains(call.id))
                default:
                    EmptyView()
                }
            }
            if let notice = message.notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AttachmentPill: View {
    let name: String
    let systemImage: String
    var onRemove: (() -> Void)?
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xs)
        .background(theme.raisedFill, in: Capsule())
        .frame(maxWidth: 200)
    }
}

struct ReasoningDisclosure: View {
    let text: String
    let isLive: Bool
    @State private var isExpanded = false
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DroppySpacing.xs) {
                    Image(systemName: "brain")
                    Text(isLive ? "Thinking…" : "Reasoning")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tertiary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ToolCallChip: View {
    let call: ToolCall
    let result: ToolResult?
    let isRunning: Bool
    @State private var isExpanded = false
    @Environment(\.chatTheme) private var theme

    private var statusImage: String {
        if isRunning || result == nil { return "circle.dotted" }
        return result?.isError == true ? "xmark.circle" : "checkmark.circle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DroppySpacing.xsm) {
                    if isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: statusImage)
                    }
                    Text(call.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, DroppySpacing.sm)
                .padding(.vertical, DroppySpacing.xsm)
                .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    Text(call.arguments.prettyPrinted())
                        .font(.system(size: 11, design: .monospaced))
                    if let result {
                        Text(String(result.text.prefix(4_000)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(result.isError ? theme.secondary : theme.tertiary)
                    }
                }
                .foregroundStyle(theme.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DroppySpacing.sm)
            }
        }
    }
}

struct ApprovalCard: View {
    let request: ApprovalRequest
    let resolve: (ApprovalDecision) -> Void
    @Environment(\.chatTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "hand.raised")
                Text("Allow \(request.toolDisplayName)?")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(theme.primary)
            Text(request.reason)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(request.call.arguments.prettyPrinted())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.tertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            HStack(spacing: DroppySpacing.sm) {
                Button("Deny") { resolve(.deny) }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Spacer()
                if !request.asksEveryTime {
                    Button("Allow for this chat") { resolve(.allowForConversation) }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
                Button("Allow") { resolve(.allowOnce) }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DroppySpacing.smd)
        .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
    }
}
