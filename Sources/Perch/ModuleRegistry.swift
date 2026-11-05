import Foundation

enum ModuleRegistry {
    static func makeModules() -> [PerchModule] {
        let env = AppEnvironment.shared
        return [
            NotchModule(env: env),
            AIModule(env: env),
            AXAgentModule(env: env),
            AgentLoopModule(env: env),
            PipModule(env: env)
        ]
    }
}
