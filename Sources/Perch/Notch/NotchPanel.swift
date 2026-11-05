import AppKit

/// 无边框透明面板：不抢焦点、不参与 Cmd-Tab、常驻状态栏层级。
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 负责面板生命周期、几何计算、悬停展开/收起动画与投放行为。
final class NotchUIController: NSObject {
    private let store: StagingStore
    private var panel: NotchPanel?
    private var content: NotchContentView?
    private var geometry: NotchGeometry?
    private var isExpanded = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var collapseWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?
    private var isDragging = false
    private var isMenuOpen = false
    /// 展开期间 0.08s 兜底轮询：鼠标移出并集后自动收起（不依赖 mouseMoved 事件）。
    private var hoverPoll: Timer?
    /// 光标离开并集的起始时刻，用于 0.15s 去抖。
    private var outsideSince: Date?
    /// 展开时刻：展开后 0.12s 内不做离开判定，避免窗口刚弹出时鼠标位置读数滞后导致的误收。
    private var expandedAt: Date?

    /// 自测/诊断用只读状态（同模块内可见）。
    var debugState: (expanded: Bool, frame: NSRect) {
        (isExpanded, panel?.frame ?? .zero)
    }

    init(store: StagingStore) {
        self.store = store
        super.init()
    }

    // MARK: 生命周期

    func start() {
        guard let screen = NotchGeometry.screenUnderMouse() else { return }
        let geo = NotchGeometry(screen: screen)
        geometry = geo

        let panel = NotchPanel(contentRect: geo.notchRect,
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.ignoresMouseEvents = false

        let content = NotchContentView(frame: NSRect(origin: .zero, size: geo.notchRect.size))
        content.autoresizingMask = [.width, .height]
        content.topInset = geo.topInset
        content.showsCollapsedHint = !geo.hasNotch
        content.setCollapsedCornerRadius(geo.cornerRadius)
        panel.contentView = content

        self.panel = panel
        self.content = content

        wireCallbacks(content)

        store.onChange = { [weak self] in
            if Thread.isMainThread {
                self?.refreshFiles()
            } else {
                DispatchQueue.main.async { self?.refreshFiles() }
            }
        }

        panel.setFrame(geo.notchRect, display: true)
        panel.orderFrontRegardless()

        installMonitors()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        refreshFiles()
    }

    func stop() {
        collapseWork?.cancel(); collapseWork = nil
        messageWork?.cancel(); messageWork = nil
        stopHoverPolling()
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        store.onChange = nil
        content?.removeFromSuperview()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        content = nil
        geometry = nil
        isExpanded = false
    }

    // MARK: 接线

    private func wireCallbacks(_ content: NotchContentView) {
        content.onDragEnter = { [weak self] in
            guard let self else { return }
            self.isDragging = true
            self.expand()
        }
        content.onDragExit = { [weak self] in
            guard let self else { return }
            self.isDragging = false
            self.content?.setHighlight(nil)
            self.outsideSince = Date()
        }
        content.onDrop = { [weak self] kind, urls in
            guard let self else { return }
            self.isDragging = false
            self.content?.setHighlight(nil)
            switch kind {
            case .airDrop: self.sendViaAirDrop(urls)
            case .staging: self.stageFiles(urls)
            }
        }
        content.onListHeightChange = { [weak self] in
            guard let self, self.isExpanded else { return }
            self.updateExpandedHeight()
        }
        content.onMenuVisibility = { [weak self] visible in
            guard let self else { return }
            self.isMenuOpen = visible
            if !visible { self.outsideSince = Date() }
        }
        content.onReveal = { [weak self] id in
            guard let self else { return }
            self.store.revealInFinder(id: id)
            self.outsideSince = Date()
        }
        content.onMouseEnter = { [weak self] in self?.expand() }
        content.onSettings = { [weak self] in
            guard let self else { return }
            if let handler = AppMenuHost.shared.onSettingsRequested {
                handler()
            } else {
                self.showMessage("设置模块尚未安装")
            }
        }
        content.onQuit = {
            NSApp.terminate(nil)
        }
        content.onDelete = { [weak self] id in
            guard let self else { return }
            do {
                try self.store.remove(id: id)
            } catch {
                self.showMessage("删除失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 展开 / 收起

    private func expand() {
        guard let panel, let content, let geo = geometry else { return }
        collapseWork?.cancel()
        guard !isExpanded else { return }
        isExpanded = true
        let target = geo.expandedFrame(extraHeight: content.listHeight)
        content.frame = NSRect(origin: .zero, size: target.size)
        content.setLayoutSize(target.size)
        content.setExpanded(true)
        outsideSince = nil
        expandedAt = Date()
        startHoverPolling()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }, completionHandler: nil)
    }

    private func collapse() {
        guard let panel, let content, let geo = geometry, isExpanded else { return }
        isExpanded = false
        outsideSince = nil
        expandedAt = nil
        stopHoverPolling()
        content.setHighlight(nil)
        content.setExpanded(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(geo.notchRect, display: true)
        }, completionHandler: { [weak self] in
            guard let self, let panel = self.panel, let geo = self.geometry, !self.isExpanded else { return }
            panel.setFrame(geo.notchRect, display: false)
            content.frame = NSRect(origin: .zero, size: geo.notchRect.size)
            content.resetLayoutSize()
        })
    }

    private func updateExpandedHeight() {
        guard isExpanded, let panel, let content, let geo = geometry else { return }
        let target = geo.expandedFrame(extraHeight: content.listHeight)
        guard abs(target.height - panel.frame.height) > 0.5 || abs(target.width - panel.frame.width) > 0.5 else { return }
        content.frame = NSRect(origin: .zero, size: target.size)
        content.setLayoutSize(target.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }, completionHandler: nil)
    }

    // MARK: 保活判定（几何并集 + 兜底轮询）

    /// 面板保持展开的判定矩形：刘海收起态矩形 ∪ 当前展开矩形（外扩 2pt 余量）。
    /// 纯几何判断，不依赖「鼠标下有没有我们自己的窗口」，避免和菜单栏状态项等其他窗口互相干扰。
    private func keepOpenRect() -> NSRect? {
        guard let geo = geometry else { return nil }
        let expanded = geo.expandedFrame(extraHeight: content?.listHeight ?? 0).insetBy(dx: -2, dy: -2)
        return geo.notchRect.union(expanded)
    }

    private func startHoverPolling() {
        stopHoverPolling()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollHover()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPoll = timer
    }

    private func stopHoverPolling() {
        hoverPoll?.invalidate()
        hoverPoll = nil
    }

    private func pollHover() {
        guard isExpanded, let keep = keepOpenRect() else { return }
        if let expandedAt, Date().timeIntervalSince(expandedAt) < 0.12 {
            outsideSince = nil
            return
        }

        // 鼠标左键按下（拖拽文件 / 拖动窗口 / 按住）期间一律不收
        if NSEvent.pressedMouseButtons == 0 { isDragging = false }
        if isDragging || isMenuOpen || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
            return
        }
        // 右键菜单、模态等也能通过窗口是否 key 等状态干扰，这里只用几何
        if keep.contains(NSEvent.mouseLocation) {
            outsideSince = nil
            return
        }
        let now = Date()
        if let since = outsideSince {
            if now.timeIntervalSince(since) >= 0.15 { collapse() }
        } else {
            outsideSince = now
        }
    }

    // MARK: 悬停检测

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if Thread.isMainThread {
                self.handleMouse(event)
            } else {
                DispatchQueue.main.async { self.handleMouse(event) }
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            handler(event)
            return event
        }
    }

    private func handleMouse(_ event: NSEvent) {
        guard let geo = geometry else { return }
        if isExpanded {
            // 事件只作为轮询的快速路径，判定与去抖都在 pollHover 里
            pollHover()
            return
        }
        if geo.hoverRect.contains(NSEvent.mouseLocation) {
            expand()
        }
    }

    @objc private func screenParametersChanged() {
        guard let screen = NotchGeometry.screenUnderMouse() else { return }
        let geo = NotchGeometry(screen: screen)
        geometry = geo
        content?.topInset = geo.topInset
        content?.showsCollapsedHint = !geo.hasNotch
        content?.setCollapsedCornerRadius(geo.cornerRadius)
        if isExpanded {
            collapse()
        } else {
            panel?.setFrame(geo.notchRect, display: true)
            content?.frame = NSRect(origin: .zero, size: geo.notchRect.size)
        }
    }

    // MARK: 数据刷新

    private func refreshFiles() {
        content?.update(files: store.files)
    }

    private func showMessage(_ text: String) {
        content?.showMessage(text)
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.content?.showMessage("") }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: 投放动作

    private func sendViaAirDrop(_ urls: [URL]) {
        let items = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else {
            showMessage("没有可投放的文件")
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            showMessage("AirDrop 不可用：系统未提供该共享服务")
            return
        }
        guard service.canPerform(withItems: items) else {
            showMessage("AirDrop 不可用：请检查 Wi-Fi 与蓝牙是否已开启")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: items)
        panel?.orderFrontRegardless()
    }

    private func stageFiles(_ urls: [URL]) {
        do {
            let staged = try store.stage(urls)
            if staged.isEmpty {
                showMessage("没有可暂存的内容")
            } else {
                let ttl = max(30, storeTTLSeconds())
                showMessage("已暂存 \(staged.count) 项，\(Int(ttl / 60)) 分钟后清除")
            }
        } catch {
            showMessage("暂存失败：\(error.localizedDescription)")
        }
    }

    private func storeTTLSeconds() -> TimeInterval {
        store.files.first.map { $0.expiresAt.timeIntervalSince($0.addedAt) } ?? 300
    }
}
