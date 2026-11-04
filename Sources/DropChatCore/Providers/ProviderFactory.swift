import Foundation

/// Turns a stored `ProviderConfig` into a live `LLMProvider`.
///
/// The registry is keyed by wire format, so a new preset on an existing
/// protocol needs no code here. To add a new protocol, implement
/// `LLMProvider` and `register` a builder for its `WireFormat`.
public final class ProviderFactory: @unchecked Sendable {
    public typealias Builder = @Sendable (ProviderConfig, String?, HTTPClient) -> any LLMProvider

    private let lock = SyncLock()
    private var builders: [WireFormat: Builder] = [:]
    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
        register(.openAIChat) { OpenAICompatibleProvider(config: $0, apiKey: $1, http: $2) }
        register(.anthropicMessages) { AnthropicProvider(config: $0, apiKey: $1, http: $2) }
        register(.geminiGenerateContent) { GoogleProvider(config: $0, apiKey: $1, http: $2) }
    }

    public func register(_ format: WireFormat, builder: @escaping Builder) {
        lock.lock()
        builders[format] = builder
        lock.unlock()
    }

    public func make(_ config: ProviderConfig, apiKey: String?) -> (any LLMProvider)? {
        lock.lock()
        let builder = builders[config.kind.wireFormat]
        lock.unlock()
        return builder?(config, apiKey, http)
    }
}
