import Foundation
import AppKit

/// 眼睛/球体的绘制状态。
struct PipEyeState {
    /// 视线方向，分量范围 -1...1，AppKit 方向（y 向上）。
    var gaze: CGPoint = .zero
    /// 额外睁大程度，0 正常，1 完全睁大（拖拽时用）。
    var openness: CGFloat = 0
    /// 眨眼程度，0 睁开，1 闭合。
    var blink: CGFloat = 0
    /// 有任务在跑时的活跃脉冲，0...1（0 = 完全静止）。
    var activity: CGFloat = 0
}

/// 纯绘制的拟物白球：径向渐变 + 边缘高光 + 柔和阴影 + 两只朝向视线的眼睛。
enum PipEyeRenderer {
    static func drawBall(in bounds: NSRect,
                         state: PipEyeState,
                         ballInsetFraction: CGFloat = 0.12,
                         shadowAlpha: CGFloat = 0.32,
                         eyeScale: CGFloat = 1.0) {
        let side = min(bounds.width, bounds.height)
        guard side > 2 else { return }

        let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let inset = side * ballInsetFraction
        let ballRect = square.insetBy(dx: inset, dy: inset)
        guard ballRect.width > 1 else { return }
        let radius = ballRect.width / 2

        drawShadow(ballRect: ballRect, side: side, alpha: shadowAlpha)
        drawBody(ballRect: ballRect)
        drawRim(ballRect: ballRect, side: side)
        drawEyes(ballRect: ballRect, radius: radius, state: state, scale: eyeScale)
        drawActivity(ballRect: ballRect, radius: radius, activity: state.activity)
    }

    /// 眼睛下方一个很淡的呼吸小点：有任务在跑时才出现，不抢眼。
    private static func drawActivity(ballRect: NSRect, radius: CGFloat, activity: CGFloat) {
        guard activity > 0.01 else { return }
        let dotRadius = max(0.8, radius * 0.10)
        let center = CGPoint(x: ballRect.midX, y: ballRect.minY + radius * 0.40)
        let alpha = 0.18 + 0.42 * min(max(activity, 0), 1)
        NSColor(white: 0.18, alpha: alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius,
                                    y: center.y - dotRadius,
                                    width: dotRadius * 2,
                                    height: dotRadius * 2)).fill()
    }

    private static func drawShadow(ballRect: NSRect, side: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        let rect = ballRect.insetBy(dx: -side * 0.10, dy: -side * 0.10)
            .offsetBy(dx: 0, dy: -side * 0.06)
        guard let gradient = NSGradient(colors: [
            NSColor.black.withAlphaComponent(alpha),
            NSColor.black.withAlphaComponent(alpha * 0.5),
            NSColor.black.withAlphaComponent(0)
        ]) else { return }
        gradient.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
    }

    private static func drawBody(ballRect: NSRect) {
        let circle = NSBezierPath(ovalIn: ballRect)
        if let body = NSGradient(colors: [
            NSColor(white: 1.0, alpha: 1),
            NSColor(white: 0.94, alpha: 1),
            NSColor(white: 0.78, alpha: 1)
        ]) {
            body.draw(in: circle, relativeCenterPosition: NSPoint(x: -0.42, y: 0.48))
        }
        // 右下角体积感（柔和内阴影）
        if let shade = NSGradient(colors: [
            NSColor(white: 0.52, alpha: 0.26),
            NSColor(white: 0.52, alpha: 0)
        ]) {
            shade.draw(in: circle, relativeCenterPosition: NSPoint(x: 0.72, y: -0.78))
        }
        // 左上方高光（镜面反射）
        let w = ballRect.width
        let h = ballRect.height
        let outer = NSRect(x: ballRect.minX + w * 0.14, y: ballRect.maxY - h * 0.34,
                           width: w * 0.34, height: h * 0.20)
        NSColor(white: 1, alpha: 0.34).setFill()
        NSBezierPath(ovalIn: outer).fill()
        let inner = NSRect(x: ballRect.minX + w * 0.20, y: ballRect.maxY - h * 0.29,
                           width: w * 0.20, height: h * 0.11)
        NSColor(white: 1, alpha: 0.82).setFill()
        NSBezierPath(ovalIn: inner).fill()
    }

    private static func drawRim(ballRect: NSRect, side: CGFloat) {
        let width = max(0.8, side * 0.028)
        let rim = NSBezierPath(ovalIn: ballRect.insetBy(dx: width * 0.5, dy: width * 0.5))
        rim.lineWidth = width
        NSColor(white: 1, alpha: 0.62).setStroke()
        rim.stroke()

        // 下缘暗边，强化球形
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: ballRect).addClip()
        let bottom = NSBezierPath(ovalIn: ballRect.insetBy(dx: width * 0.5, dy: width * 0.5))
        bottom.lineWidth = width * 1.6
        NSColor(white: 0.45, alpha: 0.18).setStroke()
        bottom.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func drawEyes(ballRect: NSRect, radius: CGFloat, state: PipEyeState, scale: CGFloat) {
        let openBoost = 1 + state.openness * 0.22
        let eyeW = radius * 0.38 * openBoost * scale
        let eyeH = max(0.7, radius * 0.52 * openBoost * (1 - state.blink * 0.94) * scale)
        let spread = radius * 0.34 * max(scale, 0.9)
        let baseY = ballRect.midY + radius * 0.06

        var shift = CGPoint(x: state.gaze.x * radius * 0.10,
                            y: state.gaze.y * radius * 0.08)
        shift.x = min(max(shift.x, -eyeW * 0.22), eyeW * 0.22)
        let maxRise = max(0, radius * 0.52 * scale - eyeH) * 0.45
        shift.y = min(max(shift.y, -maxRise), maxRise)

        for sign in [CGFloat(-1), CGFloat(1)] {
            let centerX = ballRect.midX + sign * spread
            let eyeRect = NSRect(x: centerX - eyeW / 2 + shift.x,
                                 y: baseY - eyeH / 2 + shift.y,
                                 width: eyeW, height: eyeH)
            let eye = NSBezierPath(ovalIn: eyeRect)
            NSColor(white: 0.06, alpha: 0.94).setFill()
            eye.fill()

            guard eyeH > 1.6 else { continue }
            NSGraphicsContext.current?.saveGraphicsState()
            eye.addClip()
            let glintSize = eyeW * 0.40
            let glint = NSRect(x: eyeRect.minX + eyeW * 0.16,
                               y: eyeRect.maxY - eyeH * 0.30 - glintSize * 0.5,
                               width: glintSize, height: glintSize * 0.95)
            NSColor(white: 1, alpha: 0.92).setFill()
            NSBezierPath(ovalIn: glint).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
