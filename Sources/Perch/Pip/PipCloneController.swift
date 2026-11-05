import Foundation
import AppKit

/// 一个分身：锚定在目标窗口右上角内侧的小球 + 状态灯 + 状态文字，
/// 订阅 AgentEventBus 显示进度，点击弹出「急停 / 关闭」。
final class PipCloneController {
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
    private var receivedEvent = false
    private var pulsePhase: CGFloat = 0
    private var lastFrame: CGRect

    var onRequestClose: ((PipCloneController) -> Void)?

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

        labelPanel = PipFloatingPanel(contentSize: NSSize(width: 60, height: 16), ignoresMouse: true)
        labelView = PipCloneLabelView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
        labelPanel.contentView = labelView

        ballView.onTap = { [weak self] in self?.toggleMenu() }
        ballView.status = status
        labelView.text = status.text

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
        case .step(let id, let index, _) where id == task.id:
            receivedEvent = true
            status = .running(step: index + 1)
        case .finished(let id, _) where id == task.id:
            receivedEvent = true
            status = .finished
        case .failed(let id, _) where id == task.id:
            receivedEvent = true
            status = .failed
        case .cancelled(let id) where id == task.id:
            receivedEvent = true
            status = .cancelled
        default:
            break
        }
    }

    // MARK: - Layout

    /// 锚定到目标窗口右上角内侧（AppKit 全局坐标，左下原点）。
    func reposition(to frame: CGRect) {
        lastFrame = frame
        let side = PipCloneBallView.side
        let origin = CGPoint(x: frame.maxX - 6 - side, y: frame.maxY - 6 - side)
        panel.setFrameOrigin(origin)

        // 终态只留状态灯（绿点/红点），进行中才显示「思考中 / 第 N 步」文字条。
        let size = status.isTerminal ? .zero : PipCloneLabelView.size(for: status.text)
        if size.width > 0 {
            labelPanel.setFrame(NSRect(x: origin.x - size.width - 4,
                                       y: origin.y + (side - size.height) / 2,
                                       width: size.width,
                                       height: size.height),
                                display: true)
            labelView.frame = NSRect(origin: .zero, size: size)
            labelPanel.orderFrontRegardless()
        } else {
            labelPanel.orderOut(nil)
        }

        if let menu = menuPanel, menu.isVisible {
            positionMenu(menu)
        }
    }

    private func applyStatus() {
        ballView.status = status
        labelView.text = status.text
        startPulseIfNeeded()
        reposition(to: lastFrame)
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
        menuPanel?.orderOut(nil)
        menuPanel = nil
        labelPanel.orderOut(nil)
        labelPanel.close()
        panel.orderOut(nil)
        panel.close()
        onRequestClose = nil
    }
}
