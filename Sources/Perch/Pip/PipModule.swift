import Foundation
import AppKit

/// 菜单栏里的注视球 Pip：单击出菜单，按住拖到任意窗口即可派活。
public final class PipModule: PerchModule {
    /// 集成方（ModuleRegistry）之外需要拿到实例时的入口；没有对应 env 字段可安装。
    public private(set) static weak var shared: PipModule?

    private let env: AppEnvironment

    /// 主球宿主：正常情况下是菜单栏状态项；状态项没被系统合成时换成回退浮层面板。
    private(set) var homeBall: (any PipHomeBallPresenting)?
    private(set) var statusBall: PipStatusItemBall?
    private(set) var fallbackBall: PipFallbackBall?
    /// 状态项上屏自检结果（nil = 尚未检测）。
    private(set) var statusItemOnScreen: Bool?
    private(set) var ghostPanel: PipGhostBallPanel?
    private var commandPanel: PipCommandPanel?

    private var tickTimer: Timer?
    private var trackTimer: Timer?
    private var probeTimer: Timer?

    private var smoothedGaze: CGPoint = .zero
    private var nextBlinkAt: TimeInterval = 0
    private var blinkStartedAt: TimeInterval = 0
    private var blinkActive = false
    private var isDragging = false

    private var clones: [CGWindowID: PipCloneController] = [:]
    private var pendingTarget: ScreenTarget?
    private var running = false

    public init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Lifecycle

    public func start() {
        if Thread.isMainThread { startOnMain() }
        else { DispatchQueue.main.async { [weak self] in self?.startOnMain() } }
    }

    public func stop() {
        if Thread.isMainThread { stopOnMain() }
        else { DispatchQueue.main.async { [weak self] in self?.stopOnMain() } }
    }

    private func startOnMain() {
        guard !running else { return }
        running = true
        PipModule.shared = self

        let ball = PipStatusItemBall()
        statusBall = ball
        attach(ball)

        nextBlinkAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 4...9)
        smoothedGaze = .zero

        let tick = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick

        let track = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.trackClones() }
        RunLoop.main.add(track, forMode: .common)
        trackTimer = track

        // 状态项创建后 1.5s 自检：系统没把状态项合成到菜单栏就启用回退主球。
        let probe = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.verifyHomeBallOnScreen()
        }
        RunLoop.main.add(probe, forMode: .common)
        probeTimer = probe
    }

    private func stopOnMain() {
        guard running else { return }
        running = false

        tickTimer?.invalidate(); tickTimer = nil
        trackTimer?.invalidate(); trackTimer = nil
        probeTimer?.invalidate(); probeTimer = nil

        for clone in clones.values { clone.close(cancelTask: true) }
        clones.removeAll()

        commandPanel?.dismiss()
        commandPanel = nil
        pendingTarget = nil

        removeGhost()
        homeBall?.remove()
        homeBall = nil
        statusBall = nil
        fallbackBall = nil
        isDragging = false

        if PipModule.shared === self { PipModule.shared = nil }
    }

    /// 把主球宿主的三个手势回调接到模块逻辑上（状态项与回退球走同一条路径）。
    private func attach(_ ball: any PipHomeBallPresenting) {
        ball.onTap = { [weak self] in self?.homeBall?.popMenu() }
        ball.onDragBegan = { [weak self] point in self?.beginDrag(at: point) }
        ball.onDragMoved = { [weak self] point in self?.moveDrag(to: point) }
        ball.onDragEnded = { [weak self] point in self?.endDrag(at: point) }
        homeBall = ball
    }

    // MARK: - 状态项上屏自检 / 回退

    private func verifyHomeBallOnScreen() {
        probeTimer?.invalidate()
        probeTimer = nil
        guard running, fallbackBall == nil else { return }

        let onScreen = PipHomeBallProbe.isStatusItemOnScreen()
        statusItemOnScreen = onScreen
        guard !onScreen else { return }
        installFallbackBall()
    }

    private func installFallbackBall() {
        guard let origin = PipNotchAnchor.homeOrigin(size: PipMenuBarBallView.size) else { return }
        let ball = PipFallbackBall(origin: origin)
        fallbackBall = ball
        attach(ball)
        ball.setEyeState(PipEyeState(gaze: smoothedGaze, openness: 0, blink: 0))
    }

    // MARK: - 60Hz 主循环

    private func tick() {
        guard running, let ball = homeBall else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // 视线：从球心指向全局光标，归一化到 -1...1 后用缓动逼近。
        if let center = ball.screenCenter {
            let mouse = NSEvent.mouseLocation
            var target = CGPoint(x: (mouse.x - center.x) / 160.0, y: (mouse.y - center.y) / 140.0)
            let magnitude = sqrt(target.x * target.x + target.y * target.y)
            if magnitude > 1 {
                target.x /= magnitude
                target.y /= magnitude
            }
            smoothedGaze.x += (target.x - smoothedGaze.x) * 0.22
            smoothedGaze.y += (target.y - smoothedGaze.y) * 0.22
        }

        // 眨眼：随机 4-9 秒一次，持续 0.18 秒的正弦开合。
        if !blinkActive && now >= nextBlinkAt {
            blinkActive = true
            blinkStartedAt = now
        }
        var blinkValue: CGFloat = 0
        if blinkActive {
            let progress = (now - blinkStartedAt) / 0.18
            if progress >= 1 {
                blinkActive = false
                nextBlinkAt = now + Double.random(in: 4...9)
            } else {
                blinkValue = CGFloat(sin(progress * .pi))
            }
        }

        ball.setEyeState(PipEyeState(gaze: smoothedGaze,
                                     openness: isDragging ? 1 : 0,
                                     blink: blinkValue))
    }

    private func trackClones() {
        guard !clones.isEmpty else { return }
        for (windowID, clone) in clones {
            if let frame = PipWindowProbe.appKitFrame(ofWindow: windowID) {
                clone.reposition(to: frame)
            }
        }
    }

    // MARK: - 拖拽（主球视图判定超过阈值后回调到这里）

    func beginDrag(at point: CGPoint) {
        guard running else { return }
        isDragging = true
        showGhost(at: point)
    }

    func moveDrag(to point: CGPoint) {
        guard running else { return }
        isDragging = true
        showGhost(at: point)
    }

    /// 松手：幽灵球一律移除（主球原地不动），命中窗口才弹指令面板。
    func endDrag(at point: CGPoint) {
        guard running else { return }
        isDragging = false
        removeGhost()

        guard let target = PipWindowProbe.target(atAppKitPoint: point) else { return }
        presentCommand(for: target, at: point)
    }

    private func showGhost(at point: CGPoint) {
        let panel: PipGhostBallPanel
        if let existing = ghostPanel {
            panel = existing
        } else {
            panel = PipGhostBallPanel()
            ghostPanel = panel
            panel.orderFrontRegardless()
        }
        panel.center(at: point)
    }

    private func removeGhost() {
        guard let panel = ghostPanel else { return }
        panel.orderOut(nil)
        panel.close()
        ghostPanel = nil
    }

    // MARK: - 指令面板

    private func presentCommand(for target: ScreenTarget, at point: CGPoint) {
        pendingTarget = target
        let panel = commandPanel ?? PipCommandPanel()
        commandPanel = panel
        panel.onSubmit = { [weak self] instruction in
            self?.submit(instruction: instruction)
        }
        panel.onCancel = { [weak self] in
            self?.pendingTarget = nil   // 只清悬空目标，不碰主球
        }
        panel.present(at: point)
    }

    private func dismissCommandPanel() {
        commandPanel?.dismiss()
        pendingTarget = nil
    }

    // MARK: - 派活

    private func submit(instruction: String) {
        guard let target = pendingTarget else { return }
        pendingTarget = nil

        // 同一窗口只保留一个分身：新任务替换旧任务。
        if let existing = clones[target.id] {
            clones.removeValue(forKey: target.id)
            existing.close(cancelTask: true)
        }

        let task = AgentTask(instruction: instruction,
                             target: target,
                             provider: env.settings.defaultProvider)
        let clone = PipCloneController(task: task, env: env, frame: currentFrame(of: target))
        clone.onRequestClose = { [weak self] closing in
            guard let self else { return }
            self.clones.removeValue(forKey: closing.target.id)
            closing.close(cancelTask: true)
        }
        clones[target.id] = clone
        clone.attach()

        env.agents.start(task)
    }

    /// 目标窗口此刻的 frame：优先实时查询，窗口已消失则退回拖拽时记录的 frame。
    private func currentFrame(of target: ScreenTarget) -> CGRect {
        PipWindowProbe.appKitFrame(ofWindow: target.id) ?? target.frame
    }
}
