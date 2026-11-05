import Foundation

/// 把 AgentLoopRunner 装进 AppEnvironment。
public final class AgentLoopModule: PerchModule {

    private let env: AppEnvironment
    private var runner: AgentLoopRunner?

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func start() {
        guard runner == nil else { return }
        let runner = AgentLoopRunner(env: env)
        self.runner = runner
        env.agents = runner
    }

    public func stop() {
        if let runner {
            for id in runner.activeTaskIDs {
                runner.cancel(taskID: id)
            }
        }
        runner = nil
        // 归还空实现，确保 runner 与它持有的任务句柄被释放。
        if env.agents is AgentLoopRunner {
            env.agents = NullAgentRunner()
        }
    }
}
