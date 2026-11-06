import Foundation
import AppKit

/// 把 AgentEvent 里的文本压成一行摘要。
/// AgentLoopPrompt.stepSummary 的形态是「思考｜动作标签」，所以优先取「｜」后半段；
/// 失败信息等自由文本直接整体截断。
enum PipStepSummary {
    static let separator = "｜"

    static func actionLabel(from text: String, limit: Int = 30) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.components(separatedBy: separator)
        if parts.count >= 2,
           let tail = parts.dropFirst().last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return clip(tail.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
        }
        return clip(trimmed, limit: limit)
    }

    static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// 分身的状态灯语义 + 状态条文案。
enum PipCloneStatus: Equatable {
    case starting
    case running(step: Int, total: Int, detail: String)
    case finished(detail: String)
    case failed(detail: String)
    case cancelled
    case notReady

    var text: String {
        switch self {
        case .starting:
            return "思考中"
        case .running(let step, let total, let detail):
            let head = total > 0 ? "第 \(step)/\(total) 步" : "第 \(step) 步"
            return detail.isEmpty ? head : "\(head) · \(detail)"
        case .finished(let detail):
            return detail.isEmpty ? "完成" : "完成 · \(detail)"
        case .failed(let detail):
            return detail.isEmpty ? "失败" : "失败 · \(detail)"
        case .cancelled:
            return "已取消"
        case .notReady:
            return "AI 未就绪"
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

    /// 取消只留灰点，其余状态都有文字条。
    var showsLabel: Bool {
        self != .cancelled
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

/// 分身的状态文字条：固定高 16，宽度上限 220，单行尾部截断；
/// 完全不吃鼠标事件，绝不拦截所属窗口的点击。
final class PipCloneLabelView: NSView {
    static let height: CGFloat = 16
    static let maxWidth: CGFloat = 220
    static let horizontalInset: CGFloat = 7

    private static let font = NSFont.systemFont(ofSize: 9, weight: .semibold)

    var text: String = "" {
        didSet { needsDisplay = true }
    }

    /// 文本对应的条宽（已按 220pt 封顶）。
    static func width(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return min(maxWidth, ceil(measured) + horizontalInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(white: 0.08, alpha: 0.82).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        path.lineWidth = 1
        path.stroke()

        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PipCloneLabelView.font,
            .foregroundColor: NSColor(white: 0.96, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let lineHeight = ceil(PipCloneLabelView.font.ascender - PipCloneLabelView.font.descender) + 1
        let rect = NSRect(x: PipCloneLabelView.horizontalInset,
                          y: (bounds.height - lineHeight) / 2,
                          width: max(0, bounds.width - PipCloneLabelView.horizontalInset * 2),
                          height: lineHeight)
        (text as NSString).draw(in: rect, withAttributes: attributes)
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
