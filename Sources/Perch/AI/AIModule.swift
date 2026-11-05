import Foundation
import AppKit

public final class AIModule: PerchModule {
    private let env: AppEnvironment
    private var settingsController: AISettingsWindowController?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func start() {
        env.providers = AIProviderRegistry(env: env)
        onMain { self.installSettingsEntry() }
    }

    public func stop() {
        onMain {
            AppMenuHost.shared.onSettingsRequested = nil
            self.settingsController?.closeAndRelease()
            self.settingsController = nil
            if self.env.providers is AIProviderRegistry {
                self.env.providers = NullProviderRegistry()
            }
        }
    }

    @MainActor
    private func installSettingsEntry() {
        let controller = AISettingsWindowController(env: env)
        settingsController = controller
        AppMenuHost.shared.onSettingsRequested = { [weak controller] in
            guard let controller else { return }
            MainActor.assumeIsolated { controller.show() }
        }
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }
}
