import Foundation
import AppKit

/// 分身的状态灯语义。
enum PipCloneStatus: Equatable {
    case starting
    case running(step: Int)
    case finished
    case failed
    case cancelled
    case notReady

    var text: String {
        switch self {
        case .starting: return "思考中"
        case .running(let step): return "第 \(step) 步"
        case .finished: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .notReady: return "AI 未就绪"
        }
    }

    var dotColor: NSColor {
        switch self {
        case .starting: return NSColor.systemOrange
        case .running: return NSColor.white
        case .finished: return NSColor.systemGreen
        case .failed: return NSColor.systemRed
        case .cancelled: return NSColor(white: 0.6, alpha: 1)
        case .notReady: return NSColor.systemYellow
        }
    }

    /// 需要脉冲动画的状态。
    var pulses: Bool {
        switch self {
        case .starting, .notReady: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// 分身小球视图：缩小版白球 + 状态灯。
final class PipCloneBallView: NSView {
    static let side: CGFloat = 24

    var status: PipCloneStatus = .starting {
        didSet { needsDisplay = true }
    }
    var pulse: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var onTap: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        PipEyeRenderer.drawBall(in: bounds,
                                state: PipEyeState(),
                                ballInsetFraction: 0.07,
                                shadowAlpha: 0.26,
                                eyeScale: 0.86)
        drawStatusDot()
    }

    private func drawStatusDot() {
        let radius = 3.4 + (status.pulses ? 1.0 * pulse : 0)
        let center = CGPoint(x: bounds.maxX - 4.2, y: bounds.maxY - 4.2)
        let dotRect = NSRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)

        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.3, dy: -1.3)).fill()

        let color = status.dotColor
        let alpha = status.pulses ? (0.40 + 0.60 * pulse) : 1.0
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    /// 其他 App 在前台时，第一下点击就要能唤出「急停 / 关闭」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 分身的状态文字条：完全不吃鼠标事件，绝不拦截所属窗口的点击。
final class PipCloneLabelView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: 9, weight: .semibold)

    static func size(for text: String) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 14, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(white: 0.08, alpha: 0.82).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: PipCloneLabelView.font,
            .foregroundColor: NSColor(white: 0.96, alpha: 1)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - textSize.width) / 2,
                             y: (bounds.height - textSize.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// 点分身弹出的「急停 / 关闭」小面板。
final class PipCloneMenuPanel: PipFloatingPanel {
    static let size = NSSize(width: 148, height: 40)

    var onAbort: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(contentSize: PipCloneMenuPanel.size)
        let background = PipCapsuleView(frame: NSRect(origin: .zero, size: PipCloneMenuPanel.size))
        background.cornerRadius = 10
        contentView = background

        let abort = PipFirstMouseButton(title: "急停", target: self, action: #selector(abortTapped))
        abort.frame = NSRect(x: 10, y: 8, width: 62, height: 24)
        abort.bezelStyle = .rounded
        abort.controlSize = .small
        abort.font = .systemFont(ofSize: 11, weight: .medium)
        background.addSubview(abort)

        let close = PipFirstMouseButton(title: "关闭", target: self, action: #selector(closeTapped))
        close.frame = NSRect(x: 78, y: 8, width: 60, height: 24)
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.font = .systemFont(ofSize: 11, weight: .medium)
        background.addSubview(close)
    }

    @objc private func abortTapped() { onAbort?() }
    @objc private func closeTapped() { onClose?() }
}
