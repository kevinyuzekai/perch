import Foundation
import AppKit

/// 刘海投放台模块：安装 StagingService，并托管刘海面板与投放区。
public final class NotchModule: PerchModule {
    private let env: AppEnvironment
    private var store: StagingStore?
    private var controller: NotchUIController?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        let store = StagingStore(settings: env.settings)
        env.staging = store
        self.store = store

        let controller = NotchUIController(store: store)
        controller.start()
        self.controller = controller
    }

    public func stop() {
        let finish = { [self] in
            controller?.stop()
            controller = nil
            store?.stop()
            if let store, (env.staging as AnyObject?) === store {
                env.staging = NullStagingService()
            }
            store = nil
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }
}
