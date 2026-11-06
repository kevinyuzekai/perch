import Foundation
import AppKit

/// 一个分身：锚定在目标窗口右上角内侧的小球 + 状态灯 + 状态文字条，
/// 订阅 AgentEventBus 显示「第 N/M 步 · 动作」，点击弹出「急停 / 关闭」。
final class PipCloneController {
    /// 终态文字条的停留时长（之后退化成状态灯）。
    static let finishedHold: TimeInterval = 4.0
    static let failedHold: TimeInterval = 8.0

    let target: ScreenTarget
    let task: AgentTask

    private let env: AppEnvironment
    private let panel: PipFloatingPanel
    private let ballView: PipCloneBallView
    private let labelPanel: PipFloatingPanel
    private let labelView: PipCloneLabelView

    private var menuPanel: PipCloneMenuPanel?
    private var eventToken: UUID?
    private var watchdog: Timer?
    private var pulseTimer: Timer?
    private var labelHideTimer: Timer?
    private var receivedEvent = false
    private var labelHidden = false
    /// 用于作废过期的「淡出后隐藏」回调。
    private var labelGeneration = 0
    private var pulsePhase: CGFloat = 0
    private var lastFrame: CGRect

    var onRequestClose: ((PipCloneController) -> Void)?

    /// 有任务在跑（主球据此显示活跃脉冲）。
    var isActive: Bool { !status.isTerminal }

    private var status: PipCloneStatus = .starting {
        didSet { applyStatus() }
    }

    init(task: AgentTask, env: AppEnvironment, frame: CGRect) {
        self.task = task
        self.target = task.target
        self.env = env
        self.lastFrame = frame

        panel = PipFloatingPanel(contentSize: NSSize(width: PipCloneBallView.side,
                                                     height: PipCloneBallView.side))
        ballView = PipCloneBallView(frame: NSRect(origin: .zero,
                                                  size: NSSize(width: PipCloneBallView.side,
                                                               height: PipCloneBallView.side)))
        panel.contentView = ballView

        labelPanel = PipFloatingPanel(contentSize: NSSize(width: 60, height: PipCloneLabelView.height),
                                      ignoresMouse: true)
        labelView = PipCloneLabelView(frame: NSRect(x: 0, y: 0, width: 60, height: PipCloneLabelView.height))
        labelPanel.contentView = labelView

        ballView.onTap = { [weak self] in self?.toggleMenu() }
        ballView.status = status
        labelView.text = status.text
        labelPanel.alphaValue = 1

        reposition(to: frame)
        panel.orderFrontRegardless()
        labelPanel.orderFrontRegardless()
        startPulseIfNeeded()
    }

    // MARK: - Agent

    /// 订阅事件总线并挂 3 秒看门狗（NullAgentRunner 不产生任何事件）。
    func attach() {
        eventToken = AgentEventBus.shared.subscribe { [weak self] event in
            self?.handle(event)
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self, !self.receivedEvent, !self.status.isTerminal else { return }
            self.status = .notReady
        }
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .started(let id, _) where id == task.id:
            receivedEvent = true
            if !status.isTerminal { status = .starting }
        case .step(let id, let index, let text) where id == task.id:
            receivedEvent = true
            // index 已经是 1 基（AgentLoopRunner 发的是 step+1），这里不再加一。
            status = .running(step: index,
                              total: task.maxSteps,
                              detail: PipStepSummary.actionLabel(from: text))
        case .finished(let id, let summary) where id == task.id:
            receivedEvent = true
            status = .finished(detail: PipStepSummary.clip(summary, limit: 30))
        case .failed(let id, let message) where id == task.id:
            receivedEvent = true
            status = .failed(detail: PipStepSummary.clip(message, limit: 40))
        case .cancelled(let id) where id == task.id:
            receivedEvent = true
            status = .cancelled
        default:
            break
        }
    }

    // MARK: - Layout

    /// 锚定到目标窗口右上角内侧（AppKit 全局坐标，左下原点）。
    /// 文字条右缘贴着球，宽度变化只向左生长，不会左右跳。
    func reposition(to frame: CGRect) {
        lastFrame = frame
        let side = PipCloneBallView.side
        let origin = CGPoint(x: frame.maxX - 6 - side, y: frame.maxY - 6 - side)
        panel.setFrameOrigin(origin)
        layoutLabel(ballOrigin: origin)

        if let menu = menuPanel, menu.isVisible {
            positionMenu(menu)
        }
    }

    private var labelText: String {
        labelHidden ? "" : status.text
    }

    private func layoutLabel(ballOrigin: CGPoint? = nil) {
        let text = labelView.text
        guard !text.isEmpty else {
            labelPanel.orderOut(nil)
            return
        }
        let origin = ballOrigin ?? panel.frame.origin
        let width = PipCloneLabelView.width(for: text)
        labelPanel.setFrame(NSRect(x: origin.x - width - 4,
                                   y: origin.y + (PipCloneBallView.side - PipCloneLabelView.height) / 2,
                                   width: width,
                                   height: PipCloneLabelView.height),
                            display: true)
        labelView.frame = NSRect(x: 0, y: 0, width: width, height: PipCloneLabelView.height)
        labelPanel.orderFrontRegardless()
    }

    private func applyStatus() {
        ballView.status = status
        startPulseIfNeeded()

        labelHideTimer?.invalidate()
        labelHideTimer = nil
        labelHidden = !status.showsLabel

        switch status {
        case .finished:
            scheduleLabelHide(after: PipCloneController.finishedHold)
        case .failed:
            scheduleLabelHide(after: PipCloneController.failedHold)
        default:
            break
        }

        updateLabel(animated: true)
    }

    private func scheduleLabelHide(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.labelHidden = true
            self.updateLabel(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        labelHideTimer = timer
    }

    /// 文本换得立即生效，只对透明度做 120ms 淡入淡出。
    /// 不用动画 completion 去换文本：面板不可见时 completion 可能不回调，会丢更新。
    private func updateLabel(animated: Bool) {
        labelGeneration &+= 1
        let generation = labelGeneration
        let text = labelText

        guard !text.isEmpty else {
            guard labelPanel.isVisible else { return }
            guard animated else {
                labelPanel.orderOut(nil)
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                labelPanel.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self, self.labelGeneration == generation else { return }
                self.labelPanel.orderOut(nil)
            }
            return
        }

        labelView.text = text
        layoutLabel()
        guard animated else {
            labelPanel.alphaValue = 1
            return
        }
        labelPanel.alphaValue = 0.2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            labelPanel.animator().alphaValue = 1
        }
    }

    // MARK: - Menu

    private func toggleMenu() {
        if let menu = menuPanel, menu.isVisible {
            menu.orderOut(nil)
            return
        }
        let menu = menuPanel ?? makeMenu()
        menuPanel = menu
        positionMenu(menu)
        menu.orderFrontRegardless()
    }

    private func makeMenu() -> PipCloneMenuPanel {
        let menu = PipCloneMenuPanel()
        menu.onAbort = { [weak self] in self?.abort() }
        menu.onClose = { [weak self] in
            guard let self else { return }
            self.onRequestClose?(self)
        }
        return menu
    }

    private func positionMenu(_ menu: PipCloneMenuPanel) {
        let ballFrame = panel.frame
        var origin = CGPoint(x: ballFrame.minX - menu.frame.width / 2,
                             y: ballFrame.minY - menu.frame.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(ballFrame) })?.frame {
            origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - menu.frame.width - 6)
            origin.y = min(max(origin.y, screen.minY + 6), screen.maxY - menu.frame.height - 6)
        }
        menu.setFrameOrigin(origin)
    }

    private func abort() {
        env.agents.cancel(taskID: task.id)
        status = .cancelled
        menuPanel?.orderOut(nil)
    }

    // MARK: - Pulse

    private func startPulseIfNeeded() {
        guard status.pulses else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            return
        }
        guard pulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulsePhase += 0.08
            self.ballView.pulse = (sin(self.pulsePhase * .pi) + 1) / 2
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    // MARK: - Teardown

    func close(cancelTask: Bool) {
        if cancelTask, !status.isTerminal {
            env.agents.cancel(taskID: task.id)
        }
        if let token = eventToken {
            AgentEventBus.shared.unsubscribe(token)
            eventToken = nil
        }
        watchdog?.invalidate()
        watchdog = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        labelHideTimer?.invalidate()
        labelHideTimer = nil
        menuPanel?.orderOut(nil)
        menuPanel = nil
        labelPanel.orderOut(nil)
        labelPanel.close()
        panel.orderOut(nil)
        panel.close()
        onRequestClose = nil
    }
}
