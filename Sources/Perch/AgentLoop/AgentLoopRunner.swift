import Foundation

/// 规划-执行-观察循环：把一条自然语言指令变成目标窗口内的一连串动作。
public final class AgentLoopRunner: AgentRunning {

    private let env: AppEnvironment
    private let lock = NSLock()

    private var handles: [UUID: Task<Void, Never>] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var finishedIDs: Set<UUID> = []

    private let maxAccessibilityNodes = 400
    /// 只回放最近若干轮对话，避免 context 无界增长。
    private let historyLimit = 6

    public init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - AgentRunning

    public var activeTaskIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return Array(handles.keys)
    }

    public func start(_ task: AgentTask) {
        lock.lock()
        guard handles[task.id] == nil else {
            lock.unlock()
            return
        }
        cancelledIDs.remove(task.id)
        finishedIDs.remove(task.id)
        lock.unlock()

        // 用 gate 保证 handle 先登记、后运行：release() 一定能找到自己的 handle。
        let gate = AgentLoopGate()
        let handle = Task { [weak self] in
            await gate.wait()
            guard let self else { return }
            await self.run(task)
        }

        lock.lock()
        handles[task.id] = handle
        let cancelImmediately = cancelledIDs.contains(task.id)
        lock.unlock()

        gate.open()
        if cancelImmediately {
            handle.cancel()
        }
    }

    public func cancel(taskID: UUID) {
        lock.lock()
        let handle = handles.removeValue(forKey: taskID)
        let alreadyFinished = finishedIDs.contains(taskID)
        cancelledIDs.insert(taskID)
        lock.unlock()

        // 立刻取消 Swift Task：不等正在进行的网络请求返回。
        handle?.cancel()

        // 已经正常结束的任务不再补发取消事件，避免 UI 收到互相矛盾的终态。
        if !alreadyFinished {
            AgentEventBus.shared.post(.cancelled(taskID: taskID))
        }
    }

    // MARK: - 主循环

    private func run(_ task: AgentTask) async {
        AgentEventBus.shared.post(.started(taskID: task.id, target: task.target))
        defer { release(task.id) }

        let maxSteps = max(1, task.maxSteps)
        var history: [AIMessage] = []
        var feedback: String? = nil
        var step = 0
        var retriedThisStep = false

        while step < maxSteps {
            if shouldAbort(task.id) { return }

            // (a) 观察：截图与无障碍树各自独立降级
            var observationNotes: [String] = []
            var screenshot: Data?
            var axTree: String?

            do {
                screenshot = try await env.sense.captureWindowPNG(task.target)
            } catch {
                observationNotes.append("截图失败：\(describe(error))")
            }
            if shouldAbort(task.id) { return }

            do {
                axTree = try env.sense.accessibilityTree(task.target, maxNodes: maxAccessibilityNodes)
            } catch {
                observationNotes.append("无障碍树读取失败：\(describe(error))")
            }
            if shouldAbort(task.id) { return }

            let hasTree = !(axTree ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if screenshot == nil && !hasTree {
                AgentEventBus.shared.post(.failed(
                    taskID: task.id,
                    message: "无法观察目标窗口：\(observationNotes.isEmpty ? "截图与无障碍树都不可用" : observationNotes.joined(separator: "；"))"
                ))
                return
            }

            // (b) 组装 prompt
            let systemText = AgentLoopPrompt.system(task: task, step: step + 1, maxSteps: maxSteps)
            let userText = AgentLoopPrompt.observation(axTree: hasTree ? axTree : nil, notes: observationNotes, feedback: feedback)
            feedback = nil

            var messages: [AIMessage] = [AIMessage(role: .system, text: systemText)]
            messages.append(contentsOf: history)
            messages.append(AIMessage(role: .user, text: userText, imagesPNG: screenshot.map { [$0] } ?? []))

            // (c) 取 provider
            guard let provider = env.providers.provider(for: task.provider) else {
                AgentEventBus.shared.post(.failed(taskID: task.id, message: missingProviderMessage(task.provider)))
                return
            }

            let reply: String
            do {
                reply = try await provider.chat(messages)
            } catch {
                if shouldAbort(task.id) { return }
                AgentEventBus.shared.post(.failed(
                    taskID: task.id,
                    message: "调用 \(task.provider.displayName) 失败：\(describe(error))\(missingKeyHint(task.provider))"
                ))
                return
            }
            if shouldAbort(task.id) { return }

            // (d) 解析
            let decision: AgentLoopDecision
            do {
                decision = try AgentLoopResponseParser.parse(reply)
            } catch {
                appendHistory(&history, AIMessage(role: .assistant, text: reply))
                feedback = "你的上一次回复无法解析：\(describe(error))。请只返回一个 JSON 对象，不要加任何其它文字。"
                step += 1
                retriedThisStep = false
                continue
            }

            // (e)(f) 执行与回报
            switch decision {
            case .done(let summary):
                AgentEventBus.shared.post(.finished(
                    taskID: task.id,
                    summary: summary.isEmpty ? "任务已完成。" : summary
                ))
                return

            case .action(let thought, let action, let label):
                appendHistory(&history, AIMessage(role: .assistant, text: reply))

                var performError: String?
                do {
                    try env.act.perform(action, in: task.target)
                } catch {
                    performError = describe(error)
                }

                AgentEventBus.shared.post(.step(
                    taskID: task.id,
                    index: step + 1,
                    text: AgentLoopPrompt.stepSummary(thought: thought, label: label, error: performError)
                ))

                if let performError {
                    // 同一步只重试一次：重试时进度不前进，模型带着错误文本重新观察。
                    if !retriedThisStep {
                        retriedThisStep = true
                        feedback = "上一步动作（\(label)）执行失败：\(performError)。点击可能落在了遮挡物上（浮层/其它窗口/菜单），也可能 path 已失效：请按最新截图与 AX 树判断，必要时先 focusWindow 激活窗口、或换一个 path，再重试。"
                        continue
                    }
                    retriedThisStep = false
                    feedback = "动作（\(label)）再次失败：\(performError)。请换用完全不同的方式（例如先 focusWindow 再点、改用 pressKey 走键盘路径、或对输入框先 cmd+a 再 typeText），不要重复同样的动作。"
                    step += 1
                    continue
                }

                retriedThisStep = false
                feedback = "动作（\(label)）已执行。请观察最新状态，再决定下一步。"
                step += 1
            }
        }

        AgentEventBus.shared.post(.failed(
            taskID: task.id,
            message: "已达到最大步数 \(maxSteps)，任务仍未完成。"
        ))
    }

    // MARK: - 状态辅助

    private func shouldAbort(_ id: UUID) -> Bool {
        if Task.isCancelled { return true }
        lock.lock(); defer { lock.unlock() }
        return cancelledIDs.contains(id)
    }

    private func release(_ id: UUID) {
        lock.lock()
        handles.removeValue(forKey: id)
        cancelledIDs.remove(id)
        finishedIDs.insert(id)
        if finishedIDs.count > 32 { finishedIDs.removeAll() }
        lock.unlock()
    }

    private func appendHistory(_ history: inout [AIMessage], _ message: AIMessage) {
        history.append(message)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription
        if !text.isEmpty { return text }
        return String(describing: error)
    }

    private func missingKeyHint(_ kind: AIProviderKind) -> String {
        env.keys.hasKey(for: kind) ? "" : "（没有找到 \(kind.displayName) 的 API Key，请先到设置里填写）"
    }

    private func missingProviderMessage(_ kind: AIProviderKind) -> String {
        if env.providers.availableKinds.isEmpty {
            return "没有可用的 AI 提供方：请先在设置里配置 \(kind.displayName) 的 API Key。"
        }
        let names = env.providers.availableKinds.map(\.displayName).joined(separator: "、")
        return "提供方 \(kind.displayName) 未启用：当前可用的是 \(names)。请到设置里配置它的 API Key。"
    }
}

/// 一次性放行的轻量闸门：让 start() 在登记完 handle 之后才允许主循环运行。
private final class AgentLoopGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
