import Foundation

/// The network seam. Production uses `URLSessionHTTPClient`; tests inject a
/// fake that replays recorded bodies.
public protocol HTTPClient: Sendable {
    /// Sends a request and returns the whole body.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Sends a request and streams the body line by line. Empty lines are
    /// preserved (SSE uses them as event separators). A non-2xx status throws
    /// `ProviderError.http` with the body's error message.
    func lines(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error>
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 3600
            configuration.httpAdditionalHeaders = ["User-Agent": "DropChat/0.1 (Droppy droplet)"]
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.api("The server sent no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, message: HTTPErrorBody.message(from: data))
        }
        return (data, http)
    }

    public func lines(_ request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.api("The server sent no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
            throw ProviderError.http(status: http.statusCode, message: HTTPErrorBody.message(from: body))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `AsyncBytes.lines` drops empty lines, which SSE needs,
                    // so split by hand.
                    var buffer = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pulls a human-readable message out of an error body from any of the APIs.
public enum HTTPErrorBody {
    public static func message(from data: Data) -> String {
        if let json = try? JSONValue.parse(data) {
            if let message = json["error"]?["message"]?.stringValue { return message }
            if let message = json["error"]?.stringValue { return message }
            if let message = json["message"]?.stringValue { return message }
            if let first = json[0], let message = first["error"]?["message"]?.stringValue { return message }
            if let detail = json["detail"]?.stringValue { return detail }
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "No details." : text
    }
}

public extension URLRequest {
    /// A JSON POST.
    static func jsonPost(_ url: URL, body: JSONValue, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.serializedData()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func get(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

func makeURL(_ string: String) throws -> URL {
    guard let url = URL(string: string), url.scheme != nil else { throw ProviderError.invalidURL(string) }
    return url
}
