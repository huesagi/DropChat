import Foundation

/// Adds a section to the system prompt. Skills list themselves here; a future
/// "current app" or "clipboard" context would too.
public protocol PromptContributor: Sendable {
    func systemPromptSection() async -> String?
}

public struct SystemPromptBuilder: Sendable {
    public static let defaultBasePrompt = """
    You are DropChat, an assistant that lives in the notch of the user's Mac. \
    Keep answers short and direct unless the user asks for depth; the chat window is small. \
    Use Markdown for code and lists. When tools are available, use them when they help, \
    and say briefly what you are doing before a tool call.
    """

    public var basePrompt: String
    public var contributors: [any PromptContributor]

    public init(basePrompt: String?, contributors: [any PromptContributor]) {
        let trimmed = basePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.basePrompt = trimmed.isEmpty ? Self.defaultBasePrompt : trimmed
        self.contributors = contributors
    }

    /// The date is day-granular on purpose: a timestamp would change the
    /// prompt on every request and defeat provider-side prompt caching.
    public func build(now: Date = Date(), locale: Locale = .current) async -> String {
        var sections = [basePrompt]
        let date = now.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_US")))
        sections.append("Today is \(date).")
        for contributor in contributors {
            if let section = await contributor.systemPromptSection(), !section.isEmpty {
                sections.append(section)
            }
        }
        return sections.joined(separator: "\n\n")
    }
}
