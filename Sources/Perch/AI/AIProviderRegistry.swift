import Foundation

/// 每次取 provider 都现场读 Keychain + UserDefaults，改 key / model 立即生效。
public final class AIProviderRegistry: ProviderRegistryProtocol {
    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var availableKinds: [AIProviderKind] {
        AIProviderKind.allCases.filter { env.keys.hasKey(for: $0) }
    }

    public func provider(for kind: AIProviderKind) -> AIProvider? {
        guard let key = env.keys.apiKey(for: kind),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let baseURL = env.settings.baseURL(for: kind)
        let model = env.settings.model(for: kind)
        return try? AIProviderFactory.make(kind: kind, baseURL: baseURL, apiKey: key, model: model)
    }

    /// 设置面板「测试连接」用：直接用界面上尚未保存的字段值发一次最小请求。
    public func probe(kind: AIProviderKind, baseURL: String, apiKey: String, model: String) async -> String {
        do {
            let provider = try AIProviderFactory.make(kind: kind, baseURL: baseURL,
                                                      apiKey: apiKey, model: model, maxTokens: 8)
            let reply = try await provider.chat([AIMessage(role: .user, text: "ping")])
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "连接成功（模型返回空内容）" : "连接成功：\(trimmed.prefix(80))"
        } catch {
            return "失败：\(error.localizedDescription)"
        }
    }
}
