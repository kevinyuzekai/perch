import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

public final class AXActionExecutor: ScreenAct {
    // 人类节奏参数（毫秒）
    private static let clickDwellRange: ClosedRange<Double> = 0.060...0.120
    private static let clickHoldRange: ClosedRange<Double> = 0.040...0.090
    private static let clickSettleRange: ClosedRange<Double> = 0.080...0.150
    private static let clickFallbackTimeout: Double = 0.45
    private static let keyHoldRange: ClosedRange<Double> = 0.030...0.070
    private static let charIntervalRange: ClosedRange<Double> = 0.035...0.090
    private static let typingHoldRange: ClosedRange<Double> = 0.015...0.030
    private static let longPauseRange: ClosedRange<Double> = 0.120...0.260
    private static let longPauseChance = 0.02
    private static let jitterRadius: Double = 2

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "k": 40,
        "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "grave": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "-": 27, "=": 24, "[": 33, "]": 30,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
        "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    /// 需要按住 Shift 才能打出的字符 → 其所在键的虚拟键码
    private static let shiftedKeyCodes: [Character: CGKeyCode] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28,
        "(": 25, ")": 29, "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41,
        "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50
    ]

    public init() {}

    // MARK: - 入口

    public func perform(_ action: UIAction, in target: ScreenTarget) throws {
        switch action {
        case .click(let path):
            try AXPermissionGate.requireAccessibility()
            try humanClick(path: path, pid: target.pid)
        case .setValue(let path, let value):
            try AXPermissionGate.requireAccessibility()
            try humanSetValue(path: path, value: value, pid: target.pid)
        case .focusWindow(let path):
            try AXPermissionGate.requireAccessibility()
            try focusWindow(path: path, pid: target.pid)
        case .typeText(let text):
            try AXPermissionGate.requireAccessibility()
            try typeHumanText(text)
        case .pressKey(let key, let modifiers):
            try AXPermissionGate.requireAccessibility()
            try pressKey(key, modifiers: modifiers)
        case .clickAtPoint(let x, let y):
            try AXPermissionGate.requireAccessibility()
            try humanClick(atAppKitPoint: CGPoint(x: x, y: y))
        case .openApp(let name):
            try openApplication(named: name)
        }
    }

    // MARK: - 点击

    private func humanClick(path: String, pid: pid_t) throws {
        let element = try AXElementQuery.resolve(path: path, pid: pid)
        let role = AXElementQuery.string(element, kAXRoleAttribute as String) ?? "未知角色"

        guard let frame = AXElementQuery.screenFrame(element) else {
            if press(element) { return }
            throw AXAutomationError.actionUnsupported("元素 \(role) (path=\(path)) 没有可点区域，且不支持 AXPress")
        }

        let before = snapshot(of: element)
        let center = CGPoint(x: frame.midX + Self.jitter(), y: frame.midY + Self.jitter())
        try moveMouseHuman(to: center)
        try clickHold(at: center)
        pause(Self.clickSettleRange)

        guard !waitForResponse(element, baseline: before, timeout: Self.clickFallbackTimeout) else { return }

        // 界面没有任何变化：元素可能不吃合成鼠标事件（如自绘窗口部件），退回 AXPress
        if press(element) { return }
        throw AXAutomationError.actionFailed("已用鼠标点击 \(role) (path=\(path))，但界面无响应，且该元素不支持 AXPress")
    }

    private func humanClick(atAppKitPoint point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw AXAutomationError.invalidArgument("坐标必须是有限数值：(x=\(point.x), y=\(point.y))")
        }
        // AppKit 全局坐标原点在主屏左下；CGEvent 原点在主屏左上。
        let mainDisplayHeight = Double(CGDisplayBounds(CGMainDisplayID()).height)
        let cgPoint = CGPoint(x: point.x, y: mainDisplayHeight - point.y)
        try moveMouseHuman(to: cgPoint)
        try clickHold(at: cgPoint)
        pause(Self.clickSettleRange)
    }

    private func moveMouseHuman(to destination: CGPoint) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AXAutomationError.actionFailed("无法创建 CGEventSource")
        }
        let origin = CGEvent(source: nil)?.location ?? destination
        let segments = Int.random(in: 2...3)
        var previous = origin
        for step in 1...segments {
            let progress = Double(step) / Double(segments)
            // 轨迹在中段带一点弧度，末段收敛到目标
            let bend = step == segments ? 0 : Double.random(in: -6...6)
            let point = CGPoint(
                x: origin.x + (destination.x - origin.x) * progress + bend,
                y: origin.y + (destination.y - origin.y) * progress + bend
            )
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                throw AXAutomationError.actionFailed("无法创建鼠标移动 CGEvent")
            }
            move.post(tap: .cghidEventTap)
            previous = point
            pause(0.012...0.035)
        }
        if previous != destination {
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: destination, mouseButton: .left) else {
                throw AXAutomationError.actionFailed("无法创建鼠标移动 CGEvent")
            }
            move.post(tap: .cghidEventTap)
        }
        pause(Self.clickDwellRange)
    }

    private func clickHold(at point: CGPoint) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AXAutomationError.actionFailed("无法创建 CGEventSource")
        }
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw AXAutomationError.actionFailed("无法创建鼠标 CGEvent")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        pause(Self.clickHoldRange)
        up.post(tap: .cghidEventTap)
    }

    /// 轮询元素状态，避免慢 App 尚未处理完合成点击就叠加一次 AXPress（造成双触发）
    private func waitForResponse(_ element: AXUIElement, baseline: String, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot(of: element) != baseline { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return snapshot(of: element) != baseline
    }

    @discardableResult
    private func press(_ element: AXUIElement) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        return AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success
    }

    /// 点击前后对比，用于判断界面是否真的响应了
    private func snapshot(of element: AXUIElement) -> String {
        let parts: [String] = [
            AXElementQuery.string(element, kAXRoleAttribute as String) ?? "",
            AXElementQuery.string(element, kAXValueAttribute as String) ?? "",
            AXElementQuery.string(element, kAXTitleAttribute as String) ?? "",
            AXElementQuery.string(element, kAXSelectedTextAttribute as String) ?? "",
            String(AXElementQuery.bool(element, kAXFocusedAttribute as String) ?? false),
            String(AXElementQuery.bool(element, kAXSelectedAttribute as String) ?? false),
            String(AXElementQuery.bool(element, kAXExpandedAttribute as String) ?? false),
            String(AXElementQuery.children(element).count)
        ]
        return parts.joined(separator: "|")
    }

    // MARK: - 输入

    private func humanSetValue(path: String, value: String, pid: pid_t) throws {
        let element = try AXElementQuery.resolve(path: path, pid: pid)
        let role = AXElementQuery.string(element, kAXRoleAttribute as String) ?? "未知角色"

        guard AXElementQuery.isSettable(element, kAXValueAttribute as String) else {
            // 不可编辑：不要往系统焦点里乱敲字符，直接写属性
            try writeValue(element, value: value, path: path, role: role)
            return
        }

        guard let frame = AXElementQuery.screenFrame(element) else {
            try writeValue(element, value: value, path: path, role: role)
            return
        }

        let center = CGPoint(x: frame.midX + Self.jitter(), y: frame.midY + Self.jitter())
        try moveMouseHuman(to: center)
        try clickHold(at: center)
        pause(Self.clickSettleRange)

        var eventError: Error?
        do {
            selectAll(element)
            try typeHumanText(value)
            pause(Self.clickSettleRange)
        } catch {
            eventError = error
        }

        if AXElementQuery.string(element, kAXValueAttribute as String) == value { return }

        do {
            try writeValue(element, value: value, path: path, role: role)
        } catch {
            if let eventError { throw eventError }
            throw error
        }
    }

    /// 先发人类式的 Cmd+A；校验选区没覆盖全文时，用无障碍选区兜底，避免把新文本插进旧文本中间。
    private func selectAll(_ element: AXUIElement) {
        try? pressKey("a", modifiers: ["cmd"])
        pause(0.040...0.080)
        guard !selectionCoversAll(element) else { return }
        let length = (AXElementQuery.string(element, kAXValueAttribute as String) as NSString?)?.length ?? 0
        guard length > 0 else { return }
        var range = CFRange(location: 0, length: length)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            pause(0.020...0.050)
        }
    }

    private func selectionCoversAll(_ element: AXUIElement) -> Bool {
        guard let current = AXElementQuery.string(element, kAXValueAttribute as String),
              let raw = AXElementQuery.copyAttribute(element, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return false }
        return range.location == 0 && range.length >= (current as NSString).length
    }

    private func writeValue(_ element: AXUIElement, value: String, path: String, role: String) throws {
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as NSString)
        guard error == .success else {
            throw AXAutomationError.attributeWriteFailed("元素 \(role) (path=\(path)) 不可编辑，写入 AXValue 也失败（AXError=\(error.rawValue)）")
        }
    }

    private func typeHumanText(_ text: String) throws {
        guard !text.isEmpty else { return }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)

            // 一次字符的总节拍落在 charIntervalRange 内：按住时间 + 抬手后的等待
            let beat = Double.random(in: Self.charIntervalRange)
            let hold = min(max(0.008, beat - 0.008), Double.random(in: Self.typingHoldRange))
            if let (keyCode, needsShift) = Self.keyStroke(for: character) {
                try postKey(keyCode, flags: needsShift ? .maskShift : [], characters: String(character), hold: hold...hold)
            } else {
                try postUnicode(String(character), hold: hold...hold)
            }

            wait(max(0.004, beat - hold))
            if Double.random(in: 0...1) < Self.longPauseChance {
                pause(Self.longPauseRange)
            }
        }
    }

    private static func keyStroke(for character: Character) -> (CGKeyCode, Bool)? {
        switch character {
        case " ": return (49, false)
        case "\n": return (36, false)
        case "\t": return (48, false)
        default: break
        }
        if let ascii = character.asciiValue, ascii >= 32, ascii < 127 {
            let lowered = Character(UnicodeScalar(ascii)).lowercased()
            if let keyCode = keyCodes[String(lowered)] {
                let needsShift = String(character).lowercased() != String(character) || shiftedKeyCodes[character] != nil
                return (keyCode, needsShift && (character.isUppercase || shiftedKeyCodes[character] != nil))
            }
            if let keyCode = shiftedKeyCodes[character] { return (keyCode, true) }
        }
        return nil
    }

    /// characters 非空时把字面字符写进事件载荷，避免中文输入法把按键吞成拼音组合；
    /// 快捷键（pressKey）不传 characters，保持纯键码语义。
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, characters: String? = nil, hold: ClosedRange<Double>) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AXAutomationError.actionFailed("无法创建 CGEventSource")
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw AXAutomationError.actionFailed("无法创建键盘 CGEvent")
        }
        down.flags = flags
        up.flags = flags
        if let characters {
            let units = Array(characters.utf16)
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        down.post(tap: .cghidEventTap)
        pause(hold)
        up.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ text: String, hold: ClosedRange<Double>) throws {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AXAutomationError.actionFailed("无法创建 CGEventSource")
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AXAutomationError.actionFailed("无法创建键盘 CGEvent")
        }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        pause(hold)
        up.post(tap: .cghidEventTap)
    }

    private func pressKey(_ key: String, modifiers: [String]) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keyCode = Self.keyCodes[normalized] else {
            throw AXAutomationError.invalidArgument("不支持的按键 \"\(key)\"" )
        }
        let flags = try Self.eventFlags(for: modifiers)
        try postKey(keyCode, flags: flags, hold: Self.keyHoldRange)
    }

    private static func eventFlags(for modifiers: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "", "none": continue
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt", "opt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: throw AXAutomationError.invalidArgument("不支持的修饰键 \"\(modifier)\"" )
            }
        }
        return flags
    }

    // MARK: - 窗口

    private func focusWindow(path: String, pid: pid_t) throws {
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        let element = try AXElementQuery.resolve(path: path, pid: pid)
        let raiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let mainError = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusedError = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        guard raiseError == .success || mainError == .success || focusedError == .success else {
            throw AXAutomationError.actionFailed("path=\(path) 无法置前（AXRaise=\(raiseError.rawValue), AXMain=\(mainError.rawValue), AXFocused=\(focusedError.rawValue)）")
        }
    }

    // MARK: - 工具

    private func pause(_ range: ClosedRange<Double>) {
        Thread.sleep(forTimeInterval: Double.random(in: range))
    }

    private func wait(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func jitter() -> Double {
        Double.random(in: -jitterRadius...jitterRadius)
    }

    private func openApplication(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AXAutomationError.invalidArgument("App 名称不能为空") }

        let arguments: [String]
        if trimmed.hasSuffix(".app") || trimmed.contains("/") {
            arguments = [trimmed]
        } else if trimmed.contains(".") {
            arguments = ["-b", trimmed]
        } else {
            arguments = ["-a", trimmed]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AXAutomationError.actionFailed("无法启动 \"open\"：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AXAutomationError.actionFailed("打开 App \"\(trimmed)\" 失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
