import Foundation

/// `web_search` and `web_fetch`, backed by whichever services are configured.
public final class WebToolSource: ToolSource, @unchecked Sendable {
    public let id = "web"
    public let displayName = "Web"

    let searcher: (any WebSearchProvider)?
    let fetcher: any WebFetchProvider

    public init(searcher: (any WebSearchProvider)?, fetcher: any WebFetchProvider) {
        self.searcher = searcher
        self.fetcher = fetcher
    }

    public func status() async -> ToolSourceStatus {
        .ready(detail: searcher.map { "Search with \($0.name), read pages with \(fetcher.name)" } ?? "Read pages with \(fetcher.name)")
    }

    public func tools() async -> [any ChatTool] {
        var tools: [any ChatTool] = []
        if let searcher {
            tools.append(FunctionTool(
                spec: ToolSpec(
                    name: "web_search",
                    description: "Search the web for current information. Returns titles, URLs and snippets\(searcher is PerplexityProvider ? " (and sometimes a written answer)" : ""). Cite the URLs you use.",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "The search query."],
                            "limit": ["type": "integer", "description": "How many results, 1 to 10.", "minimum": 1, "maximum": 10],
                        ],
                        "required": ["query"],
                    ]
                ),
                displayName: "Search the web",
                sourceID: id,
                run: { arguments, _ in
                    let query = try arguments.requiredString("query")
                    let limit = max(1, min(arguments["limit"]?.intValue ?? 6, 10))
                    let response = try await searcher.search(query, limit: limit)
                    return ToolOutput(text: WebToolSource.render(response))
                }
            ))
        }
        let fetcher = self.fetcher
        tools.append(FunctionTool(
            spec: ToolSpec(
                name: "web_fetch",
                description: "Read the text of one or more web pages (up to 5 URLs).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "urls": ["type": "array", "items": ["type": "string"], "description": "Absolute http(s) URLs."],
                        "max_characters": ["type": "integer", "description": "Characters per page, default 12000."],
                    ],
                    "required": ["urls"],
                ]
            ),
            displayName: "Read web pages",
            sourceID: id,
            run: { arguments, _ in
                let urls = arguments["urls"]?.arrayValue?.compactMap(\.stringValue) ?? arguments["url"]?.stringValue.map { [$0] } ?? []
                guard !urls.isEmpty else { throw ToolArgumentError.missing("urls") }
                let limit = max(500, min(arguments["max_characters"]?.intValue ?? 12_000, 50_000))
                let pages = try await fetcher.fetch(Array(urls.prefix(5)), maxCharacters: limit)
                guard !pages.isEmpty else { return .error("No readable content came back for those URLs.") }
                return ToolOutput(text: pages.map { page in
                    "<page url=\"\(page.url)\" title=\"\(page.title ?? "")\">\n\(page.text)\n</page>"
                }.joined(separator: "\n\n"))
            }
        ))
        return tools
    }

    static func render(_ response: WebSearchResponse) -> String {
        var lines: [String] = []
        if let answer = response.answer, !answer.isEmpty {
            lines.append("Answer:\n\(answer)\n")
        }
        if response.results.isEmpty {
            lines.append("No results.")
        }
        for (index, result) in response.results.enumerated() {
            var line = "[\(index + 1)] \(result.title)\n\(result.url)"
            if let date = result.publishedDate { line += " (\(date))" }
            if !result.snippet.isEmpty { line += "\n\(result.snippet)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n\n")
    }
}
