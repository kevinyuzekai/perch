import Foundation
import AppKit

/// 拖拽时跟着光标的「幽灵球」：只是视觉替身，不吃鼠标事件、不能成为 key window。
final class PipGhostBallView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        PipEyeRenderer.drawBall(in: bounds,
                                state: PipEyeState(gaze: .zero, openness: 1, blink: 0),
                                ballInsetFraction: 0.07,
                                shadowAlpha: 0.26)
    }
}

final class PipGhostBallPanel: PipFloatingPanel {
    static let side: CGFloat = 26

    init() {
        super.init(contentSize: NSSize(width: PipGhostBallPanel.side, height: PipGhostBallPanel.side),
                   acceptsKey: false,
                   ignoresMouse: true)
        contentView = PipGhostBallView(frame: NSRect(x: 0, y: 0,
                                                     width: PipGhostBallPanel.side,
                                                     height: PipGhostBallPanel.side))
    }

    /// 让球心跟随给定的 AppKit 屏幕坐标。
    func center(at point: CGPoint) {
        setFrameOrigin(CGPoint(x: point.x - PipGhostBallPanel.side / 2,
                               y: point.y - PipGhostBallPanel.side / 2))
    }
}
