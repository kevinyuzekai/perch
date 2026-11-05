import Foundation
import AppKit

public final class AXAgentModule: PerchModule {
    private let env: AppEnvironment
    private var capture: AXScreenCapture?
    private var executor: AXActionExecutor?
    private var isRunning = false

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func start() {
        guard !isRunning else { return }
        let capture = AXScreenCapture()
        let executor = AXActionExecutor()
        env.sense = capture
        env.act = executor
        self.capture = capture
        self.executor = executor
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        if let capture, env.sense === capture { env.sense = NullScreenSense() }
        if let executor, env.act === executor { env.act = NullScreenAct() }
        capture = nil
        executor = nil
        isRunning = false
    }
}
