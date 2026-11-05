import Foundation

// MARK: - Errors

public enum AIProviderError {
    public static let domain = "Perch.AI"

    public static func http(_ status: Int, _ bodySnippet: String) -> NSError {
        NSError(domain: domain, code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)：\(bodySnippet)"])
    }

    public static func malformed(_ detail: String) -> NSError {
        NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    public static func config(_ detail: String) -> NSError {
        NSError(domain: domain, code: -2, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}

// MARK: - HTTP plumbing

enum AIHTTP {
    /// 60s per-request timeout, as required by every provider.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    static func post(url: URL, headers: [String: String], body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.malformed("网络请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.malformed("响应不是 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIProviderError.http(http.statusCode, snippet(from: data))
        }
        return data
    }

    static func snippet(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(空响应体)" }
        return String(trimmed.prefix(300))
    }

    static func endpoint(baseURL: String, path: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + path)
    }
}

// MARK: - OpenAI compatible wire format (DeepSeek / ChatGPT / Grok / custom)

public final class AIOpenAICompatibleProvider: AIProvider {
    public let kind: AIProviderKind
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let temperature: Double

    public init(kind: AIProviderKind,
                baseURL: String,
                apiKey: String,
                model: String,
                maxTokens: Int = 1024,
                temperature: Double = 0.2) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    public func chat(_ messages: [AIMessage]) async throws -> String {
        guard let url = AIHTTP.endpoint(baseURL: baseURL, path: "/chat/completions") else {
            throw AIProviderError.config("baseURL 无效：\(baseURL)")
        }
        guard !model.isEmpty else {
            throw AIProviderError.config("model 为空，请在设置中填写")
        }

        let body = try requestBody(messages)
        let data = try await AIHTTP.post(url: url,
                                         headers: ["Authorization": "Bearer \(apiKey)"],
                                         body: body)
        return try parseContent(data)
    }

    // MARK: wire

    private func requestBody(_ messages: [AIMessage]) throws -> Data {
        var encoded: [[String: Any]] = []
        for message in messages {
            let role = message.role.rawValue
            if message.imagesPNG.isEmpty {
                encoded.append(["role": role, "content": message.text])
            } else {
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["type": "text", "text": message.text])
                }
                for png in message.imagesPNG {
                    let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
                    parts.append(["type": "image_url", "image_url": ["url": dataURL]])
                }
                if parts.isEmpty {
                    parts.append(["type": "text", "text": ""])
                }
                encoded.append(["role": role, "content": parts])
            }
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": encoded,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw AIProviderError.malformed("请求体编码失败：\(error.localizedDescription)")
        }
    }

    private func parseContent(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.malformed("无法解析 JSON：\(AIHTTP.snippet(from: data))")
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIProviderError.malformed("响应缺少 choices：\(AIHTTP.snippet(from: data))")
        }
        guard let message = first["message"] as? [String: Any] else {
            throw AIProviderError.malformed("响应缺少 message：\(AIHTTP.snippet(from: data))")
        }
        if let text = message["content"] as? String {
            return text
        }
        // Some gateways return content as an array of parts.
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        throw AIProviderError.malformed("响应缺少 content：\(AIHTTP.snippet(from: data))")
    }
}

// MARK: - Anthropic Messages wire format

public final class AIAnthropicProvider: AIProvider {
    public let kind: AIProviderKind
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let maxTokens: Int

    public init(kind: AIProviderKind = .anthropic,
                baseURL: String,
                apiKey: String,
                model: String,
                maxTokens: Int = 1024) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
    }

    public func chat(_ messages: [AIMessage]) async throws -> String {
        guard let url = AIHTTP.endpoint(baseURL: baseURL, path: "/messages") else {
            throw AIProviderError.config("baseURL 无效：\(baseURL)")
        }
        guard !model.isEmpty else {
            throw AIProviderError.config("model 为空，请在设置中填写")
        }

        let body = try requestBody(messages)
        let data = try await AIHTTP.post(url: url,
                                         headers: [
                                            "x-api-key": apiKey,
                                            "anthropic-version": "2023-06-01"
                                         ],
                                         body: body)
        return try parseText(data)
    }

    private func requestBody(_ messages: [AIMessage]) throws -> Data {
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var encoded: [[String: Any]] = []
        for message in messages where message.role != .system {
            var blocks: [[String: Any]] = []
            if !message.text.isEmpty {
                blocks.append(["type": "text", "text": message.text])
            }
            for png in message.imagesPNG {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": png.base64EncodedString()
                    ]
                ])
            }
            if blocks.isEmpty {
                blocks.append(["type": "text", "text": ""])
            }
            encoded.append(["role": message.role.rawValue, "content": blocks])
        }

        var payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": encoded
        ]
        if !systemText.isEmpty { payload["system"] = systemText }

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw AIProviderError.malformed("请求体编码失败：\(error.localizedDescription)")
        }
    }

    private func parseText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.malformed("无法解析 JSON：\(AIHTTP.snippet(from: data))")
        }
        if let blocks = root["content"] as? [[String: Any]] {
            if let first = blocks.first, let text = first["text"] as? String {
                return text
            }
            let joined = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !joined.isEmpty { return joined }
        }
        throw AIProviderError.malformed("响应缺少 content: \(AIHTTP.snippet(from: data))")
    }
}

// MARK: - Factory

public enum AIProviderFactory {
    public static func make(kind: AIProviderKind,
                            baseURL: String,
                            apiKey: String,
                            model: String,
                            maxTokens: Int = 1024) throws -> AIProvider {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AIProviderError.config("\(kind.displayName)：尚未配置 API Key")
        }
        if kind.usesAnthropicWireFormat {
            return AIAnthropicProvider(kind: kind, baseURL: baseURL, apiKey: key,
                                       model: model, maxTokens: maxTokens)
        }
        return AIOpenAICompatibleProvider(kind: kind, baseURL: baseURL, apiKey: key,
                                          model: model, maxTokens: maxTokens)
    }
}
