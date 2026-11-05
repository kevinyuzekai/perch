import Foundation
import Combine

public enum AITestState: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)

    var isRunning: Bool { self == .running }
}

/// 单个 Provider 的编辑态（一行）。
@MainActor
public final class AIProviderSettingsRow: ObservableObject, Identifiable {
    public nonisolated let kind: AIProviderKind

    @Published var apiKey: String
    @Published var model: String
    @Published var baseURL: String
    @Published var testState: AITestState = .idle
    @Published private(set) var storedHasKey: Bool

    let initialKey: String

    public nonisolated var id: String { kind.rawValue }

    init(env: AppEnvironment, kind: AIProviderKind) {
        self.kind = kind
        let existing = env.keys.apiKey(for: kind) ?? ""
        self.apiKey = existing
        self.initialKey = existing
        self.model = env.settings.model(for: kind)
        self.baseURL = env.settings.baseURL(for: kind)
        self.storedHasKey = !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 有可用于请求的 key：已存进 Keychain，或输入框里新填的。
    public var hasUsableKey: Bool {
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !typed.isEmpty || storedHasKey
    }

    public func markSaved() {
        storedHasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
public final class AISettingsModel: ObservableObject {
    let env: AppEnvironment
    private let registry: AIProviderRegistry

    @Published var rows: [AIProviderSettingsRow]
    @Published var defaultProvider: AIProviderKind
    @Published var stagingTTLText: String
    /// 刷新 ticks（权限状态需要手动触发重绘）
    @Published var permissionTick: Int = 0
    @Published var errorMessage: String?

    var onClose: ((Bool) -> Void)?

    public init(env: AppEnvironment) {
        self.env = env
        let registry = AIProviderRegistry(env: env)
        self.registry = registry
        self.rows = AIProviderKind.allCases.map { AIProviderSettingsRow(env: env, kind: $0) }
        self.defaultProvider = env.settings.defaultProvider
        self.stagingTTLText = "\(Int(env.settings.stagingTTL))"
    }

    // MARK: permissions

    var hasAccessibility: Bool { env.permissions.hasAccessibility }
    var hasScreenRecording: Bool { env.permissions.hasScreenRecording }

    func refreshPermissions() {
        permissionTick &+= 1
    }

    func requestAccessibility() {
        env.permissions.requestAccessibility()
        refreshPermissions()
    }

    func requestScreenRecording() {
        env.permissions.requestScreenRecording()
        refreshPermissions()
    }

    func openAccessibilitySettings() { env.permissions.openAccessibilitySettings() }
    func openScreenRecordingSettings() { env.permissions.openScreenRecordingSettings() }

    // MARK: actions

    func runTest(_ row: AIProviderSettingsRow) {
        guard row.hasUsableKey, !row.testState.isRunning else { return }
        row.testState = .running
        let kind = row.kind
        let baseURL = row.baseURL
        let model = row.model
        let key = row.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (env.keys.apiKey(for: kind) ?? "")
            : row.apiKey

        Task { @MainActor in
            let outcome = await registry.probe(kind: kind, baseURL: baseURL, apiKey: key, model: model)
            if outcome.hasPrefix("失败") {
                row.testState = .failure(outcome)
            } else {
                row.testState = .success(outcome)
            }
        }
    }

    func save() -> Bool {
        let ttl = Double(stagingTTLText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let parsed = ttl, parsed.isFinite, parsed >= 5, parsed <= 86_400 else {
            errorMessage = "暂存保留秒数需在 5–86400 之间"
            return false
        }

        for row in rows {
            let key = row.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key != row.initialKey {
                env.keys.setAPIKey(key.isEmpty ? nil : key, for: row.kind)
            }
            env.settings.setModel(row.model.trimmingCharacters(in: .whitespacesAndNewlines), for: row.kind)
            env.settings.setBaseURL(row.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), for: row.kind)
            row.markSaved()
        }

        env.settings.stagingTTL = parsed
        if env.keys.hasKey(for: defaultProvider) {
            env.settings.defaultProvider = defaultProvider
        } else if let fallback = AIProviderKind.allCases.first(where: { env.keys.hasKey(for: $0) }) {
            env.settings.defaultProvider = fallback
        } else {
            env.settings.defaultProvider = defaultProvider
        }

        errorMessage = nil
        return true
    }

    func saveAndClose() {
        if save() { onClose?(true) }
    }

    func cancel() {
        onClose?(false)
    }
}
