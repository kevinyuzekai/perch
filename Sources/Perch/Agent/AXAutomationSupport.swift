import Foundation
import ApplicationServices
import CoreGraphics

// MARK: - 错误

public enum AXAutomationError: LocalizedError {
    case accessibilityNotTrusted
    case screenRecordingNotTrusted
    case applicationUnavailable(pid_t)
    case windowNotFound(CGWindowID)
    case displayNotFound
    case invalidPath(String)
    case invalidArgument(String)
    case elementNotFound(String)
    case actionUnsupported(String)
    case actionFailed(String)
    case attributeWriteFailed(String)
    case captureFailed(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "未获得「辅助功能」权限。请到 系统设置 → 隐私与安全性 → 辅助功能 中勾选 Perch 后重试。"
        case .screenRecordingNotTrusted:
            return "未获得「屏幕录制」权限。请到 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 Perch 后重试。"
        case .applicationUnavailable(let pid):
            return "无法访问进程 pid=\(pid) 的无障碍信息，目标 App 可能已退出或尚未完成启动。"
        case .windowNotFound(let id):
            return "找不到 windowID=\(id) 的窗口，它可能已关闭或被最小化。"
        case .displayNotFound:
            return "找不到可用的显示器，无法截图。"
        case .invalidPath(let path):
            return "元素路径格式不合法：\(path)（应为形如 0/2/1 的索引路径）。"
        case .invalidArgument(let detail):
            return "参数不合法：\(detail)"
        case .elementNotFound(let path):
            return "元素已过期或不存在：path=\(path)。界面可能已刷新，请重新读取无障碍树。"
        case .actionUnsupported(let detail):
            return "该元素不支持此操作：\(detail)"
        case .actionFailed(let detail):
            return "操作失败：\(detail)"
        case .attributeWriteFailed(let detail):
            return "写入属性失败：\(detail)"
        case .captureFailed(let detail):
            return "截图失败：\(detail)"
        case .encodeFailed(let detail):
            return "PNG 编码失败：\(detail)"
        }
    }
}

// MARK: - 权限闸门

enum AXPermissionGate {
    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw AXAutomationError.accessibilityNotTrusted }
    }

    static func requireScreenRecording() throws {
        guard CGPreflightScreenCaptureAccess() else { throw AXAutomationError.screenRecordingNotTrusted }
    }
}

// MARK: - AX 属性读取

enum AXElementQuery {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute) as? NSNumber else { return nil }
        return value.boolValue
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func windows(_ application: AXUIElement) -> [AXUIElement] {
        if let value = copyAttribute(application, kAXWindowsAttribute as String),
           let windows = value as? [AXUIElement], !windows.isEmpty {
            return windows
        }
        // 部分 App 未实现 AXWindows，用 AXChildren 兜底（其子元素通常就是窗口）
        return children(application)
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as String),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 优先 AXFrame，其次 position+size；返回值遵循无障碍坐标系（origin 在主屏左上）。
    static func screenFrame(_ element: AXUIElement) -> CGRect? {
        if let value = copyAttribute(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
                return rect
            }
        }
        if let frame = frame(element), frame.width > 0, frame.height > 0 { return frame }
        return nil
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var flag = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success else { return false }
        return flag.boolValue
    }

    static func isHidden(_ element: AXUIElement) -> Bool {
        bool(element, kAXHiddenAttribute as String) ?? false
    }

    /// 从 App 元素起按 "0/2/1" 索引路径逐级下行；每次调用都重新解析，不缓存 AXUIElement。
    static func resolve(path: String, pid: pid_t) throws -> AXUIElement {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { throw AXAutomationError.invalidPath(path) }
        var indices: [Int] = []
        indices.reserveCapacity(components.count)
        for component in components {
            guard let index = Int(component), index >= 0 else { throw AXAutomationError.invalidPath(path) }
            indices.append(index)
        }

        let application = AXUIElementCreateApplication(pid)
        let root = windows(application)
        guard let first = indices.first else { throw AXAutomationError.invalidPath(path) }
        guard first < root.count else { throw AXAutomationError.elementNotFound(path) }
        var current = root[first]
        for index in indices.dropFirst() {
            let level = children(current)
            guard index < level.count else { throw AXAutomationError.elementNotFound(path) }
            current = level[index]
        }
        guard copyAttribute(current, kAXRoleAttribute as String) != nil else {
            throw AXAutomationError.elementNotFound(path)
        }
        return current
    }
}

// MARK: - 文本工具

enum AXText {
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}

// MARK: - PNG 编码

import ImageIO

enum AXPNG {
    static func encode(_ image: CGImage) throws -> Data {
        guard let mutable = CFDataCreateMutable(nil, 0) else {
            throw AXAutomationError.encodeFailed("无法创建缓冲区")
        }
        guard let destination = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil) else {
            throw AXAutomationError.encodeFailed("无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AXAutomationError.encodeFailed("PNG 写入未完成")
        }
        return mutable as Data
    }
}
