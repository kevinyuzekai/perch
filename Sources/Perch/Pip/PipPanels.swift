import Foundation
import AppKit

/// Pip 的浮层面板（幽灵球 / 指令面板 / 分身 / 分身菜单）共用。
/// - .nonactivatingPanel：点击不会把 Perch 激活/抢走前台 app 的焦点。
/// - level .statusBar：浮在普通窗口之上。
/// 主球不在其中——主球是菜单栏里的 NSStatusItem。
class PipFloatingPanel: NSPanel {
    private let acceptsKey: Bool

    init(contentSize: NSSize, acceptsKey: Bool = false, ignoresMouse: Bool = false) {
        self.acceptsKey = acceptsKey
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = ignoresMouse
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// 首击即生效的输入框：面板弹出瞬间 Perch 可能还不是前台 App，
/// 默认实现会把第一次点击让给「激活 App」，导致点不进去光标。
final class PipFirstMouseTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 首击即生效的按钮（分身菜单里的「急停 / 关闭」）。
final class PipFirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 绘制圆角半透明底板的小工具视图（用于输入框与状态标签）。
final class PipCapsuleView: NSView {
    var fillColor: NSColor = NSColor(white: 0.10, alpha: 0.94) {
        didSet { needsDisplay = true }
    }
    var borderColor: NSColor = NSColor(white: 1, alpha: 0.14) {
        didSet { needsDisplay = true }
    }
    var cornerRadius: CGFloat = 12 {
        didSet { needsDisplay = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
