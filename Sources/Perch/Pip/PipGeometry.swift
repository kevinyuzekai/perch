import Foundation
import AppKit
import CoreGraphics

/// 屏幕坐标换算。
///
/// 系统里存在两套全局坐标系：
/// - CGWindowList / CoreGraphics：原点在主屏**左上角**，y 向下增长。
/// - AppKit（NSScreen / NSWindow / NSEvent.mouseLocation）：原点在主屏**左下角**，y 向上增长。
///
/// ScreenTarget.frame 统一使用 AppKit 全局坐标（左下原点），便于直接喂给 NSWindow。
enum PipCoordinates {
    /// 主屏：frame.origin == .zero 的那块屏幕（CG 全局原点的锚点）。
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
    }

    static var primaryTopY: CGFloat { primaryScreen?.frame.maxY ?? 0 }

    /// AppKit 全局点 → CG 全局点（左上原点）。
    static func coreGraphicsPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryTopY - point.y)
    }

    /// CG 全局点 → AppKit 全局点（左下原点）。
    static func appKitPoint(fromCoreGraphics point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryTopY - point.y)
    }

    /// CGWindowList 的 bounds（左上原点）→ AppKit 全局 frame（左下原点）。
    /// 高度不变，只需把「上边的 y」翻成「下边的 y」。
    static func appKitRect(fromCoreGraphics rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTopY - rect.maxY, width: rect.width, height: rect.height)
    }
}
/// 回退主球的落位（只在状态项没被系统合成时使用）：
/// 刘海右缘 +8pt、距屏幕顶边 6pt。
enum PipNotchAnchor {
    /// 带刘海的屏幕；没有就退回主屏。
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopRightArea != nil }
            ?? PipCoordinates.primaryScreen
    }

    /// 刘海右缘的 AppKit 全局 x。
    static var notchRightEdgeX: CGFloat? {
        guard let screen = screen else { return nil }
        if let aux = screen.auxiliaryTopRightArea {
            // auxiliaryTopRightArea 是该屏幕自身坐标系（原点在屏幕左下角）。
            return screen.frame.minX + aux.minX
        }
        // 无刘海的外接屏：把屏幕水平中点当作零宽刘海的右缘。
        return screen.frame.midX
    }

    static func homeOrigin(size: NSSize) -> CGPoint? {
        guard let right = notchRightEdgeX, let screen = screen else { return nil }
        return CGPoint(x: right + 8, y: screen.frame.maxY - 6 - size.height)
    }
}
