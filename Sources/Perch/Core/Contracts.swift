import Foundation
import AppKit
import CoreGraphics

public protocol PerchModule: AnyObject {
    func start()
    func stop()
}

// MARK: - AI

public protocol AIProvider: AnyObject {
    var kind: AIProviderKind { get }
    func chat(_ messages: [AIMessage]) async throws -> String
}

public protocol ProviderRegistryProtocol: AnyObject {
    var availableKinds: [AIProviderKind] { get }
    func provider(for kind: AIProviderKind) -> AIProvider?
}

public protocol KeyStoreProtocol: AnyObject {
    func apiKey(for kind: AIProviderKind) -> String?
    func setAPIKey(_ key: String?, for kind: AIProviderKind)
    func hasKey(for kind: AIProviderKind) -> Bool
}

public protocol SettingsStoreProtocol: AnyObject {
    var stagingTTL: TimeInterval { get set }
    var defaultProvider: AIProviderKind { get set }
    func model(for kind: AIProviderKind) -> String
    func setModel(_ model: String, for kind: AIProviderKind)
    func baseURL(for kind: AIProviderKind) -> String
    func setBaseURL(_ url: String, for kind: AIProviderKind)
}

// MARK: - Staging

public protocol StagingService: AnyObject {
    var files: [StagedFile] { get }
    var onChange: (() -> Void)? { get set }
    @discardableResult func stage(_ urls: [URL]) throws -> [StagedFile]
    func remove(id: UUID) throws
    func clear() throws
    func itemProvider(for id: UUID) -> NSItemProvider?
    func revealInFinder(id: UUID)
}

// MARK: - Screen sensing / acting

public protocol ScreenSense: AnyObject {
    func captureWindowPNG(_ target: ScreenTarget) async throws -> Data
    func captureFullScreenPNG() async throws -> Data
    func accessibilityTree(_ target: ScreenTarget, maxNodes: Int) throws -> String
}

public enum UIAction {
    case click(elementPath: String)
    case setValue(elementPath: String, value: String)
    case typeText(String)
    case pressKey(key: String, modifiers: [String])
    case focusWindow(elementPath: String)
    case clickAtPoint(x: Double, y: Double)
    case openApp(named: String)
}

public protocol ScreenAct: AnyObject {
    func perform(_ action: UIAction, in target: ScreenTarget) throws
}

// MARK: - Agent

public struct AgentTask: Identifiable {
    public let id: UUID
    public var instruction: String
    public var target: ScreenTarget
    public var provider: AIProviderKind
    public var maxSteps: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), instruction: String, target: ScreenTarget, provider: AIProviderKind, maxSteps: Int = 12, createdAt: Date = Date()) {
        self.id = id
        self.instruction = instruction
        self.target = target
        self.provider = provider
        self.maxSteps = maxSteps
        self.createdAt = createdAt
    }
}

public enum AgentEvent {
    case started(taskID: UUID, target: ScreenTarget)
    case step(taskID: UUID, index: Int, text: String)
    case finished(taskID: UUID, summary: String)
    case failed(taskID: UUID, message: String)
    case cancelled(taskID: UUID)
}

public protocol AgentRunning: AnyObject {
    var activeTaskIDs: [UUID] { get }
    func start(_ task: AgentTask)
    func cancel(taskID: UUID)
}

/// 多播事件总线：Agent 运行器发布，任何 UI 模块订阅（避免单回调抢占）
public final class AgentEventBus {
    public static let shared = AgentEventBus()
    private var observers: [UUID: (AgentEvent) -> Void] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping (AgentEvent) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: token)
    }

    public func post(_ event: AgentEvent) {
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        let deliver = { for handler in handlers { handler(event) } }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}

/// 菜单栏设置入口（Settings 模块注册，AppDelegate 触发）
public final class AppMenuHost {
    public static let shared = AppMenuHost()
    public var onSettingsRequested: (() -> Void)?
    public init() {}
}
