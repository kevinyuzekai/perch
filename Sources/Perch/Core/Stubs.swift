import Foundation
import AppKit

public final class NullProviderRegistry: ProviderRegistryProtocol {
    public init() {}
    public var availableKinds: [AIProviderKind] { [] }
    public func provider(for kind: AIProviderKind) -> AIProvider? { nil }
}

public final class NullKeyStore: KeyStoreProtocol {
    public init() {}
    public func apiKey(for kind: AIProviderKind) -> String? { nil }
    public func setAPIKey(_ key: String?, for kind: AIProviderKind) {}
    public func hasKey(for kind: AIProviderKind) -> Bool { false }
}

public final class DefaultSettingsStore: SettingsStoreProtocol {
    private let defaults = UserDefaults.standard

    public init() {}

    public var stagingTTL: TimeInterval {
        get {
            let stored = defaults.double(forKey: "stagingTTL")
            return stored > 0 ? stored : 300
        }
        set { defaults.set(newValue, forKey: "stagingTTL") }
    }

    public var defaultProvider: AIProviderKind {
        get { AIProviderKind(rawValue: defaults.string(forKey: "defaultProvider") ?? "") ?? .deepseek }
        set { defaults.set(newValue.rawValue, forKey: "defaultProvider") }
    }

    public func model(for kind: AIProviderKind) -> String {
        defaults.string(forKey: "model.\(kind.rawValue)") ?? kind.defaultModel
    }

    public func setModel(_ model: String, for kind: AIProviderKind) {
        defaults.set(model, forKey: "model.\(kind.rawValue)")
    }

    public func baseURL(for kind: AIProviderKind) -> String {
        defaults.string(forKey: "baseURL.\(kind.rawValue)") ?? kind.defaultBaseURL
    }

    public func setBaseURL(_ url: String, for kind: AIProviderKind) {
        defaults.set(url, forKey: "baseURL.\(kind.rawValue)")
    }
}

public final class NullStagingService: StagingService {
    public init() {}
    public var files: [StagedFile] { [] }
    public var onChange: (() -> Void)?
    @discardableResult public func stage(_ urls: [URL]) throws -> [StagedFile] { [] }
    public func remove(id: UUID) throws {}
    public func clear() throws {}
    public func itemProvider(for id: UUID) -> NSItemProvider? { nil }
    public func revealInFinder(id: UUID) {}
}

public final class NullScreenSense: ScreenSense {
    public init() {}
    public func captureWindowPNG(_ target: ScreenTarget) async throws -> Data {
        throw NSError(domain: "Perch", code: -1, userInfo: [NSLocalizedDescriptionKey: "截图模块尚未安装"])
    }
    public func captureFullScreenPNG() async throws -> Data {
        throw NSError(domain: "Perch", code: -1, userInfo: [NSLocalizedDescriptionKey: "截图模块尚未安装"])
    }
    public func accessibilityTree(_ target: ScreenTarget, maxNodes: Int) throws -> String { "" }
}

public final class NullScreenAct: ScreenAct {
    public init() {}
    public func perform(_ action: UIAction, in target: ScreenTarget) throws {
        throw NSError(domain: "Perch", code: -1, userInfo: [NSLocalizedDescriptionKey: "操作模块尚未安装"])
    }
}

public final class NullAgentRunner: AgentRunning {
    public init() {}
    public var activeTaskIDs: [UUID] { [] }
    public func start(_ task: AgentTask) {}
    public func cancel(taskID: UUID) {}
}
