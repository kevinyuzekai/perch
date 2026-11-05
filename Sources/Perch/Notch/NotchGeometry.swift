import AppKit

/// 刘海在屏幕上的真实矩形（AppKit 全局点坐标，原点为屏幕左下角）。
/// 无刘海屏时退化为顶部居中的胶囊矩形。
public struct NotchGeometry {
    /// 展开后投放区暴露的高度（刘海下方）。
    public static let revealHeight: CGFloat = 96
    /// 展开态每侧额外横向宽度。
    public static let horizontalReveal: CGFloat = 120

    public let screen: NSScreen
    public let notchRect: NSRect
    public let hasNotch: Bool
    public let cornerRadius: CGFloat
    /// 面板顶部需要避开的高度（刘海 / 菜单栏）。
    public let topInset: CGFloat

    public static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return hit }
        return NSScreen.main ?? NSScreen.screens.first
    }

    public init(screen: NSScreen) {
        self.screen = screen
        let frame = screen.frame
        let insets = screen.safeAreaInsets
        let menuBarInset = max(0, frame.maxY - screen.visibleFrame.maxY)
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea

        let barHeight = max(insets.top > 0 ? insets.top : menuBarInset, 24)

        if let l = left, let r = right, r.minX > l.maxX, l.width > 1, r.width > 1 {
            let width = r.minX - l.maxX
            self.notchRect = NSRect(x: l.maxX, y: frame.maxY - barHeight, width: width, height: barHeight)
            self.hasNotch = true
            self.cornerRadius = min(10, max(6, barHeight * 0.28))
        } else {
            let width: CGFloat = 120
            let height: CGFloat = 24
            self.notchRect = NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
            self.hasNotch = false
            self.cornerRadius = height / 2
        }
        self.topInset = notchRect.height
    }

    /// 展开态窗口矩形：顶边贴着屏幕顶部，向下长高，水平居中于刘海。
    public func expandedFrame(extraHeight: CGFloat) -> NSRect {
        let width = min(max(notchRect.width + 2 * Self.horizontalReveal, 320), max(320, screen.frame.width - 40))
        let height = topInset + Self.revealHeight + max(0, extraHeight)
        return NSRect(x: notchRect.midX - width / 2, y: notchRect.maxY - height, width: width, height: height)
    }

    /// 鼠标进入该矩形即展开（向下多留一点，方便从刘海下沿触发）。
    public var hoverRect: NSRect {
        NSRect(x: notchRect.minX - 8, y: notchRect.minY - 10, width: notchRect.width + 16, height: notchRect.height + 10)
    }
}
