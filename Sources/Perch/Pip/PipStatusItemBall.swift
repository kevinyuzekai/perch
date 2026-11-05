import Foundation
import AppKit

/// 主球视图（菜单栏状态项与回退面板共用同一份绘制与手势逻辑）：
/// 只负责绘制，并把鼠标手势翻译成屏幕坐标回调。
/// 故意不设 target/action、也不给 statusItem 设 menu，
/// 否则松开时系统会自己弹菜单、并把拖拽手势吞掉。
final class PipMenuBarBallView: NSView {
    static let size = NSSize(width: 26, height: 22)
    /// 拖拽判定阈值（pt）。
    static let dragThreshold: CGFloat = 3

    var state = PipEyeState() {
        didSet { needsDisplay = true }
    }

    var onTap: (() -> Void)?
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    private var pressPoint: CGPoint = .zero
    private var dragging = false

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        PipEyeRenderer.drawBall(in: bounds,
                                state: state,
                                ballInsetFraction: 0.04,
                                shadowAlpha: 0.16,
                                eyeScale: 0.92)
    }

    /// 视图在屏幕上的矩形（AppKit 全局坐标）。
    var screenRect: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// 事件自带的窗口内坐标 → 屏幕坐标。
    /// 不用 NSEvent.mouseLocation：那是「当前」光标，事件排队或快速拖动时与事件本身不同步。
    private func screenPoint(of event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = screenPoint(of: event) else { return }
        pressPoint = point
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = screenPoint(of: event) else { return }
        if !dragging {
            let distance = abs(point.x - pressPoint.x) + abs(point.y - pressPoint.y)
            guard distance > PipMenuBarBallView.dragThreshold else { return }
            // 判定为拖拽后由自己接管整个手势：松手走 onDragEnded，绝不走 onTap 弹菜单。
            dragging = true
            onDragBegan?(point)
        }
        onDragMoved?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = screenPoint(of: event) else { return }
        if dragging {
            dragging = false
            onDragEnded?(point)
        } else {
            onTap?()
        }
    }
}

/// 菜单栏主球宿主：NSStatusItem + 自定义视图。
final class PipStatusItemBall: NSObject, PipHomeBallPresenting {
    let view: PipMenuBarBallView
    private let item: NSStatusItem
    private let menuTarget = PipHomeBallMenuTarget()
    private lazy var menu = PipHomeBallMenu.make(target: menuTarget)

    override init() {
        view = PipMenuBarBallView(frame: NSRect(origin: .zero, size: PipMenuBarBallView.size))
        item = NSStatusBar.system.statusItem(withLength: PipMenuBarBallView.size.width)
        super.init()

        if let button = item.button {
            // 用自定义视图当内容：标题/图标都清空，避免系统再画一遍。
            button.title = ""
            button.image = nil
            button.addSubview(view)
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
        }
    }

    var screenCenter: CGPoint? {
        guard let rect = view.screenRect else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 状态栏窗口 frame（AppKit 全局坐标）。
    var windowFrame: CGRect? { view.window?.frame }

    /// 主球（状态项按钮里那块视图）在屏幕上的矩形，AppKit 全局坐标。
    var screenFrame: CGRect? { view.screenRect }

    /// 菜单（供自检/验证读取条目）。
    var menuItems: [NSMenuItem] { menu.items }

    var onTap: (() -> Void)? {
        get { view.onTap }
        set { view.onTap = newValue }
    }

    var onDragBegan: ((CGPoint) -> Void)? {
        get { view.onDragBegan }
        set { view.onDragBegan = newValue }
    }

    var onDragMoved: ((CGPoint) -> Void)? {
        get { view.onDragMoved }
        set { view.onDragMoved = newValue }
    }

    var onDragEnded: ((CGPoint) -> Void)? {
        get { view.onDragEnded }
        set { view.onDragEnded = newValue }
    }

    func setEyeState(_ state: PipEyeState) {
        view.state = state
    }

    func popMenu() {
        PipHomeBallMenu.pop(menu, from: view)
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }
}
