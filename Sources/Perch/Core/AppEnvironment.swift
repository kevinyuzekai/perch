import Foundation
import AppKit

public final class AppEnvironment {
    public static let shared = AppEnvironment()

    public var providers: ProviderRegistryProtocol = NullProviderRegistry()
    public var keys: KeyStoreProtocol = KeychainKeyStore()
    public var settings: SettingsStoreProtocol = DefaultSettingsStore()
    public var staging: StagingService = NullStagingService()
    public var sense: ScreenSense = NullScreenSense()
    public var act: ScreenAct = NullScreenAct()
    public var agents: AgentRunning = NullAgentRunner()
    public let permissions = PermissionService()

    public init() {}
}
