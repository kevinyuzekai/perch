import Foundation
import AppKit
import CoreGraphics

public struct ScreenTarget: Identifiable, Hashable {
    public var id: CGWindowID
    public var pid: pid_t
    public var appName: String
    public var windowTitle: String
    public var frame: CGRect

    public init(id: CGWindowID, pid: pid_t, appName: String, windowTitle: String, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.windowTitle = windowTitle
        self.frame = frame
    }
}

public enum AIProviderKind: String, CaseIterable, Codable, Identifiable {
    case deepseek
    case openai
    case grok
    case anthropic
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "ChatGPT"
        case .grok: return "Grok"
        case .anthropic: return "Anthropic"
        case .custom: return "自定义"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .custom: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o"
        case .grok: return "grok-2-latest"
        case .anthropic: return "claude-sonnet-4-5"
        case .custom: return ""
        }
    }

    public var usesAnthropicWireFormat: Bool { self == .anthropic }
}

public struct AIMessage {
    public enum Role: String {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var text: String
    public var imagesPNG: [Data]

    public init(role: Role, text: String, imagesPNG: [Data] = []) {
        self.role = role
        self.text = text
        self.imagesPNG = imagesPNG
    }
}

public struct StagedFile: Identifiable {
    public let id: UUID
    public let url: URL
    public let originalURL: URL
    public let addedAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), url: URL, originalURL: URL, addedAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.url = url
        self.originalURL = originalURL
        self.addedAt = addedAt
        self.expiresAt = expiresAt
    }

    public var displayName: String { url.lastPathComponent }
    public var remaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }
}
