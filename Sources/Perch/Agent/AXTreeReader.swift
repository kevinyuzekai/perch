import Foundation
import ApplicationServices
import CoreGraphics

public final class AXTreeReader {
    public static let maxDepth = 12
    public static let lineCharacterLimit = 120
    public static let outputCharacterLimit = 12000

    public init() {}

    public func accessibilityTree(_ target: ScreenTarget, maxNodes: Int) throws -> String {
        try AXPermissionGate.requireAccessibility()

        let nodeBudget = max(1, maxNodes)
        let application = AXUIElementCreateApplication(target.pid)

        guard AXElementQuery.copyAttribute(application, kAXRoleAttribute as String) != nil else {
            throw AXAutomationError.applicationUnavailable(target.pid)
        }

        let windows = AXElementQuery.windows(application)
        guard !windows.isEmpty else { return "" }

        var stack: [(element: AXUIElement, path: String, depth: Int)] = []
        stack.reserveCapacity(64)
        for index in stride(from: windows.count - 1, through: 0, by: -1) {
            stack.append((windows[index], "\(index)", 0))
        }

        var lines: [String] = []
        var emitted = 0
        var truncated = false
        var total = 0

        while let node = stack.popLast() {
            guard node.depth <= AXTreeReader.maxDepth else { continue }
            guard !AXElementQuery.isHidden(node.element) else { continue }

            if let line = renderLine(node.element, path: node.path, depth: node.depth) {
                if emitted >= nodeBudget {
                    truncated = true
                    break
                }
                if total + line.count + 1 > AXTreeReader.outputCharacterLimit {
                    truncated = true
                    break
                }
                lines.append(line)
                total += line.count + 1
                emitted += 1
            }

            guard node.depth < AXTreeReader.maxDepth else { continue }
            let children = AXElementQuery.children(node.element)
            guard !children.isEmpty else { continue }
            for index in stride(from: children.count - 1, through: 0, by: -1) {
                stack.append((children[index], node.path + "/\(index)", node.depth + 1))
            }
        }

        if truncated {
            lines.append("…（输出已截断，仅显示前 \(emitted) 个元素）")
        }
        return lines.joined(separator: "\n")
    }

    private func renderLine(_ element: AXUIElement, path: String, depth: Int) -> String? {
        let role = AXElementQuery.string(element, kAXRoleAttribute as String) ?? "AXUnknown"
        guard role != "AXUnknown" else { return nil }

        if let frame = AXElementQuery.frame(element), frame.width < 0.5 || frame.height < 0.5 {
            return nil
        }

        var line = String(repeating: "  ", count: depth) + "[\(path)] \(role)"

        if let identifier = AXElementQuery.string(element, kAXIdentifierAttribute as String), !identifier.isEmpty {
            line += " id=\(AXText.singleLine(identifier))"
        }

        let title = AXElementQuery.string(element, kAXTitleAttribute as String) ?? ""
        if !title.isEmpty {
            line += " \"\(AXText.singleLine(title))\""
        }

        if let value = AXElementQuery.string(element, kAXValueAttribute as String), !value.isEmpty {
            line += " value=\"\(AXText.singleLine(value))\""
        }

        return AXText.truncate(line, limit: AXTreeReader.lineCharacterLimit)
    }
}
