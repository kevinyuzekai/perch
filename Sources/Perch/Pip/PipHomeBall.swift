import Foundation
import AppKit
import CoreGraphics

/// 「主球」宿主抽象：菜单栏状态项与（本机不合成状态项时的）回退浮层面板各实现一份。
/// 上层（幽灵球 / 命中 / 指令面板 / 分身）只依赖本协议，不区分宿主。
protocol PipHomeBallPresenting: AnyObject {
    /// 球心（AppKit 全局坐标），用于算视线朝向。
    var screenCenter: CGPoint? { get }
    var onTap: (() -> Void)? { get set }
    var onDragBegan: ((CGPoint) -> Void)? { get set }
    var onDragMoved: ((CGPoint) -> Void)? { get set }
    var onDragEnded: ((CGPoint) -> Void)? { get set }

    func setEyeState(_ state: PipEyeState)
    func popMenu()
    func remove()
}

/// 菜单动作目标（NSMenuItem.target 是弱引用，宿主必须自己持有它）。
final class PipHomeBallMenuTarget: NSObject {
    @objc func openSettings() { AppMenuHost.shared.onSettingsRequested?() }
    @objc func quit() { NSApp.terminate(nil) }
}

enum PipHomeBallMenu {
    static func make(target: PipHomeBallMenuTarget) -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Perch 设置与权限…",
                                  action: #selector(PipHomeBallMenuTarget.openSettings),
                                  keyEquivalent: "")
        settings.target = target
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Perch",
                              action: #selector(PipHomeBallMenuTarget.quit),
                              keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
        return menu
    }

    /// 贴着球的下沿弹出。
    static func pop(_ menu: NSMenu, from view: NSView) {
        menu.popUp(positioning: nil,
                   at: NSPoint(x: view.bounds.midX, y: view.bounds.minY - 2),
                   in: view)
    }
}

/// 回退主球：状态项被系统吞掉时使用的普通浮层面板，交互与状态项完全一致。
final class PipFallbackBall: PipHomeBallPresenting {
    let view: PipMenuBarBallView
    private let panel: PipFloatingPanel
    private let menuTarget = PipHomeBallMenuTarget()
    private lazy var menu = PipHomeBallMenu.make(target: menuTarget)

    init(origin: CGPoint) {
        view = PipMenuBarBallView(frame: NSRect(origin: .zero, size: PipMenuBarBallView.size))
        panel = PipFloatingPanel(contentSize: PipMenuBarBallView.size,
                                 acceptsKey: false,
                                 ignoresMouse: false)
        panel.contentView = view
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    var screenCenter: CGPoint? {
        guard let rect = view.screenRect else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

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
        panel.orderOut(nil)
        panel.close()
    }
}

/// 运行时自检：状态项窗口到底有没有被系统合成到菜单栏。
/// 判据 = 本进程存在一个「宽≈26（26 本身，或包住它的约 42 宽状态栏窗口）、
/// 高 21...34、贴着屏幕顶部（CG 左上原点 minY ≤ 8）」的在屏窗口。
enum PipHomeBallProbe {
    struct ScreenWindow {
        let rect: CGRect          // CG 全局坐标（左上原点）
        let ownerName: String
    }

    static let expectedWidth: CGFloat = 26
    static let widthTolerance: CGFloat = 16
    static let minHeight: CGFloat = 21
    static let maxHeight: CGFloat = 34
    static let topTolerance: CGFloat = 8

    /// 本进程当前在屏的窗口（CG 左上原点）。
    static func selfScreenWindows() -> [ScreenWindow] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [ScreenWindow] = []
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid == selfPID else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            let name = (info[kCGWindowName as String] as? String) ?? "Perch"
            result.append(ScreenWindow(rect: rect, ownerName: name))
        }
        return result
    }

    static func looksLikeStatusItem(_ rect: CGRect) -> Bool {
        abs(rect.width - expectedWidth) <= widthTolerance
            && rect.height >= minHeight
            && rect.height <= maxHeight
            && rect.minY <= topTolerance
    }

    static func isStatusItemOnScreen() -> Bool {
        selfScreenWindows().contains { looksLikeStatusItem($0.rect) }
    }
}
