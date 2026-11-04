import Foundation

public struct WebSearchResult: Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String
    public var publishedDate: String?

    public init(title: String, url: String, snippet: String, publishedDate: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedDate = publishedDate
    }
}

public struct WebSearchResponse: Sendable {
    /// A synthesized answer, when the backend writes one (Perplexity Sonar).
    public var answer: String?
    public var results: [WebSearchResult]

    public init(answer: String? = nil, results: [WebSearchResult]) {
        self.answer = answer
        self.results = results
    }
}

public struct WebPage: Sendable {
    public var url: String
    public var title: String?
    public var text: String
}

/// A web search backend. Add one by conforming and listing it in `WebBackend`.
public protocol WebSearchProvider: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> WebSearchResponse
}

/// A page reader ("crawler").
public protocol WebFetchProvider: Sendable {
    var name: String { get }
    func fetch(_ urls: [String], maxCharacters: Int) async throws -> [WebPage]
}

public enum WebBackend: String, Codable, CaseIterable, Sendable {
    case exa
    case perplexity

    public var displayName: String {
        switch self {
        case .exa: return "Exa"
        case .perplexity: return "Perplexity"
        }
    }

    public var secretAccount: String { "web.\(rawValue)" }
}

// MARK: - Exa

public struct ExaProvider: WebSearchProvider, WebFetchProvider {
    public let name = "Exa"
    let apiKey: String
    let http: HTTPClient
    let baseURL = "https://api.exa.ai"

    public init(apiKey: String, http: HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    var headers: [String: String] { ["x-api-key": apiKey] }

    public func search(_ query: String, limit: Int) async throws -> WebSearchResponse {
        let body: JSONValue = [
            "query": .string(query),
            "numResults": .number(Double(limit)),
            "type": "auto",
            "contents": ["highlights": ["numSentences": 3, "highlightsPerUrl": 2], "text": ["maxCharacters": 1_500]],
        ]
        let (data, _) = try await http.send(.jsonPost(try makeURL(baseURL + "/search"), body: body, headers: headers))
        let json = try JSONValue.parse(data)
        let results = (json["results"]?.arrayValue ?? []).map { item -> WebSearchResult in
            let highlights = item["highlights"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " … ")
            let snippet = (highlights?.isEmpty == false ? highlights : nil) ?? item["text"]?.stringValue ?? item["summary"]?.stringValue ?? ""
            return WebSearchResult(
                title: item["title"]?.stringValue ?? item["url"]?.stringValue ?? "Untitled",
                url: item["url"]?.stringValue ?? "",
                snippet: snippet,
                publishedDate: item["publishedDate"]?.stringValue
            )
        }
        return WebSearchResponse(results: results)
    }

    public func fetch(_ urls: [String], maxCharacters: Int) async throws -> [WebPage] {
        let body: JSONValue = [
            "urls": .array(urls.map { .string($0) }),
            "text": ["maxCharacters": .number(Double(maxCharacters))],
            "livecrawl": "preferred",
        ]
        let (data, _) = try await http.send(.jsonPost(try makeURL(baseURL + "/contents"), body: body, headers: headers))
        let json = try JSONValue.parse(data)
        return (json["results"]?.arrayValue ?? []).map { item in
            WebPage(url: item["url"]?.stringValue ?? "", title: item["title"]?.stringValue, text: item["text"]?.stringValue ?? "")
        }
    }
}

// MARK: - Perplexity

public struct PerplexityProvider: WebSearchProvider {
    public let name = "Perplexity"
    let apiKey: String
    let http: HTTPClient
    /// `search` returns ranked results; `sonar` writes an answer with citations.
    let mode: PerplexityMode

    public init(apiKey: String, mode: PerplexityMode, http: HTTPClient) {
        self.apiKey = apiKey
        self.mode = mode
        self.http = http
    }

    var headers: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    public func search(_ query: String, limit: Int) async throws -> WebSearchResponse {
        switch mode {
        case .search: return try await rawSearch(query, limit: limit)
        case .sonar: return try await sonar(query)
        }
    }

    func rawSearch(_ query: String, limit: Int) async throws -> WebSearchResponse {
        let body: JSONValue = ["query": .string(query), "max_results": .number(Double(min(limit, 20)))]
        let (data, _) = try await http.send(.jsonPost(try makeURL("https://api.perplexity.ai/search"), body: body, headers: headers))
        let json = try JSONValue.parse(data)
        let results = (json["results"]?.arrayValue ?? []).map { item in
            WebSearchResult(
                title: item["title"]?.stringValue ?? "Untitled",
                url: item["url"]?.stringValue ?? "",
                snippet: item["snippet"]?.stringValue ?? "",
                publishedDate: item["date"]?.stringValue
            )
        }
        return WebSearchResponse(results: results)
    }

    func sonar(_ query: String) async throws -> WebSearchResponse {
        let body: JSONValue = [
            "model": "sonar",
            "messages": [["role": "user", "content": .string(query)]],
        ]
        let (data, _) = try await http.send(.jsonPost(try makeURL("https://api.perplexity.ai/chat/completions"), body: body, headers: headers))
        let json = try JSONValue.parse(data)
        let answer = json["choices"]?[0]?["message"]?["content"]?.stringValue
        var results = (json["search_results"]?.arrayValue ?? []).map { item in
            WebSearchResult(title: item["title"]?.stringValue ?? "Source", url: item["url"]?.stringValue ?? "", snippet: item["snippet"]?.stringValue ?? "", publishedDate: item["date"]?.stringValue)
        }
        if results.isEmpty {
            results = (json["citations"]?.arrayValue ?? []).compactMap(\.stringValue).map { WebSearchResult(title: $0, url: $0, snippet: "") }
        }
        return WebSearchResponse(answer: answer, results: results)
    }
}

public enum PerplexityMode: String, Codable, CaseIterable, Sendable {
    case search
    case sonar

    public var label: String {
        switch self {
        case .search: return "Search results"
        case .sonar: return "Sonar answer with sources"
        }
    }
}

// MARK: - Plain fetcher

/// Reads a page directly, without a crawling service. Used for `web_fetch`
/// when no Exa key is set.
public struct BasicWebFetcher: WebFetchProvider {
    public let name = "Direct"
    let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    public func fetch(_ urls: [String], maxCharacters: Int) async throws -> [WebPage] {
        var pages: [WebPage] = []
        for raw in urls.prefix(5) {
            let url = try makeURL(raw)
            guard url.scheme == "https" || url.scheme == "http" else { continue }
            var request = URLRequest.get(url, headers: ["Accept": "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5"])
            request.timeoutInterval = 30
            let (data, response) = try await http.send(request)
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            let body = String(decoding: data.prefix(3_000_000), as: UTF8.self)
            var title: String?
            var text = body
            if type.contains("html") || body.prefix(2_000).lowercased().contains("<html") {
                let extracted = HTMLText.extract(body)
                title = extracted.title
                text = extracted.text
            }
            pages.append(WebPage(url: raw, title: title, text: String(text.prefix(maxCharacters))))
        }
        return pages
    }
}

/// A small, dependency-free HTML to text conversion.
public enum HTMLText {
    public static func extract(_ html: String) -> (title: String?, text: String) {
        var text = html
        let title = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: text).map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#, #"<svg[\s\S]*?</svg>"#, #"<!--[\s\S]*?-->"#, #"<head[\s\S]*?</head>"#, #"<nav[\s\S]*?</nav>"#, #"<footer[\s\S]*?</footer>"#] {
            text = replace(pattern, in: text, with: " ")
        }
        text = replace(#"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>"#, in: text, with: "\n")
        text = replace(#"<li[^>]*>"#, in: text, with: "\n• ")
        text = replace(#"<[^>]+>"#, in: text, with: " ")
        text = decodeEntities(text)
        text = replace(#"[ \t\x{00A0}]+"#, in: text, with: " ")
        text = replace(#"\n\s*\n+"#, in: text, with: "\n\n")
        return (title, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func decodeEntities(_ text: String) -> String {
        var output = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in named { output = output.replacingOccurrences(of: entity, with: value) }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") else { return output }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: output), let code = Range(match.range(at: 1), in: output) else { continue }
            let raw = output[code]
            let value = raw.hasPrefix("x") || raw.hasPrefix("X") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
            if let value, let scalar = Unicode.Scalar(value) {
                output.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return output
    }
}
