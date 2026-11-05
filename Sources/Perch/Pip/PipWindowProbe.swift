import Foundation
import AppKit
import CoreGraphics

/// 通过 CGWindowList 做窗口命中与跟随。
enum PipWindowProbe {
    /// 过小的窗口通常是阴影/辅助窗口，直接忽略。
    static let minimumSize = CGSize(width: 60, height: 40)

    /// 命中给定 AppKit 全局点下最上层、不属于 Perch 的普通窗口。
    static func target(atAppKitPoint point: CGPoint) -> ScreenTarget? {
        let cgPoint = PipCoordinates.coreGraphicsPoint(fromAppKit: point)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // CGWindowList 的返回顺序是「前 → 后」，第一个命中的就是最上层。
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            // 排除 Perch 自己（球、分身、指令面板都属于本进程）。
            guard ownerPID != selfPID else { continue }
            guard let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha > 0.01 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            guard cgRect.width >= minimumSize.width, cgRect.height >= minimumSize.height else { continue }
            guard cgRect.contains(cgPoint) else { continue }
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }

            let windowID = CGWindowID(number.uint32Value)
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "未知应用"
            let title = (info[kCGWindowName as String] as? String) ?? ownerName
            let appKitFrame = PipCoordinates.appKitRect(fromCoreGraphics: cgRect)
            return ScreenTarget(id: windowID,
                                pid: ownerPID,
                                appName: ownerName,
                                windowTitle: title,
                                frame: appKitFrame)
        }
        return nil
    }

    /// 按 CGWindowID 查当前 frame（AppKit 全局坐标），窗口不存在时返回 nil。
    static func appKitFrame(ofWindow windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  CGWindowID(number.uint32Value) == windowID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            return PipCoordinates.appKitRect(fromCoreGraphics: cgRect)
        }
        return nil
    }
}
