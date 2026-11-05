import Foundation

// MARK: - 解析结果

/// 模型一次回复的语义：要么执行一个动作，要么声明任务已完成。
public enum AgentLoopDecision {
    case action(thought: String, action: UIAction, label: String)
    case done(summary: String)
}

public enum AgentLoopParseError: Error, LocalizedError, Equatable {
    case noJSONObject
    case invalidJSON(String)
    case missingField(String)
    case unknownAction(String)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "回复里找不到任何 JSON 对象"
        case .invalidJSON(let detail):
            return "JSON 无法解析：\(detail)"
        case .missingField(let name):
            return "缺少字段 \(name)"
        case .unknownAction(let type):
            return "不支持的动作类型 \(type)"
        case .invalidField(let detail):
            return "字段不合法：\(detail)"
        }
    }
}

// MARK: - 括号配对扫描 + JSON 解析

public enum AgentLoopResponseParser {

    /// 从左到右扫描出所有括号平衡的 JSON 对象候选（不靠正则）。
    /// 字符串内的引号与反斜杠转义会被跳过，所以字符串里的花括号与引号不会打断配对。
    public static func balancedObjects(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var results: [String] = []
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for index in scalars.indices {
            let scalar = scalars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }
            switch scalar {
            case "\"":
                if start != nil { inString = true }
            case "{":
                if start == nil { start = index }
                depth += 1
            case "}":
                if start != nil {
                    depth -= 1
                    if depth == 0, let begin = start {
                        results.append(String(String.UnicodeScalarView(scalars[begin...index])))
                        start = nil
                    }
                }
            default:
                break
            }
        }
        return results
    }

    /// 第一个括号平衡的对象（即使它只是噪音里的花括号片段）。
    public static func firstJSONObject(in text: String) -> String? {
        balancedObjects(in: text).first
    }

    /// 依次试每个平衡候选，取第一个能解码成 JSON 字典的对象来产出决策。
    /// 因此 JSON 被代码块包裹、前后夹说明文字、或前面先出现带花括号的废话，都能正确取到。
    public static func parse(_ reply: String) throws -> AgentLoopDecision {
        let candidates = balancedObjects(in: reply)
        guard !candidates.isEmpty else { throw AgentLoopParseError.noJSONObject }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  let root = raw as? [String: Any] else { continue }
            return try decision(from: root)
        }
        throw AgentLoopParseError.invalidJSON("花括号内容里没有能解析的 JSON 对象")
    }

    private static func decision(from root: [String: Any]) throws -> AgentLoopDecision {
        if let done = root["done"] as? Bool, done {
            return .done(summary: summary(from: root))
        }
        if let doneText = root["done"] as? String, doneText.lowercased() == "true" {
            return .done(summary: summary(from: root))
        }
        if root["action"] == nil, let text = root["summary"] as? String, !text.isEmpty {
            // 模型漏了 done 标记但给了 summary，按完成处理。
            return .done(summary: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let thought = (root["thought"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let actionObject = root["action"] as? [String: Any] else {
            throw AgentLoopParseError.missingField("action")
        }
        guard let type = actionObject["type"] as? String, !type.isEmpty else {
            throw AgentLoopParseError.missingField("action.type")
        }

        let action: UIAction
        let label: String
        switch type {
        case "click":
            let element = try path(from: actionObject)
            action = .click(elementPath: element)
            label = "点击元素 \(element)"
        case "setValue":
            let element = try path(from: actionObject)
            let value = (actionObject["value"] as? String) ?? stringify(actionObject["value"])
            guard !value.isEmpty else { throw AgentLoopParseError.invalidField("setValue 需要非空 value") }
            action = .setValue(elementPath: element, value: value)
            label = "把 \(element) 设为「\(clip(value, 60))」"
        case "typeText":
            guard let text = actionObject["text"] as? String, !text.isEmpty else {
                throw AgentLoopParseError.invalidField("typeText 需要非空 text")
            }
            action = .typeText(text)
            label = "输入文本「\(clip(text, 60))」"
        case "pressKey":
            guard let key = actionObject["key"] as? String, !key.isEmpty else {
                throw AgentLoopParseError.invalidField("pressKey 需要非空 key")
            }
            let modifiers = (actionObject["modifiers"] as? [Any])?.compactMap { $0 as? String } ?? []
            action = .pressKey(key: key, modifiers: modifiers)
            label = modifiers.isEmpty ? "按键 \(key)" : "按键 \(modifiers.joined(separator: "+"))+\(key)"
        case "focusWindow":
            let element = try path(from: actionObject)
            action = .focusWindow(elementPath: element)
            label = "聚焦窗口元素 \(element)"
        case "clickAtPoint":
            guard let x = number(actionObject["x"]), let y = number(actionObject["y"]) else {
                throw AgentLoopParseError.invalidField("clickAtPoint 需要数值 x 与 y")
            }
            action = .clickAtPoint(x: x, y: y)
            label = "点击坐标 (\(Int(x)), \(Int(y)))"
        case "openApp":
            guard let name = actionObject["name"] as? String, !name.isEmpty else {
                throw AgentLoopParseError.invalidField("openApp 需要非空 name")
            }
            action = .openApp(named: name)
            label = "打开应用 \(name)"
        default:
            throw AgentLoopParseError.unknownAction(type)
        }
        return .action(thought: thought, action: action, label: label)
    }

    // MARK: - 字段辅助

    private static func summary(from root: [String: Any]) -> String {
        ((root["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func path(from object: [String: Any]) throws -> String {
        guard let value = object["path"] as? String else {
            throw AgentLoopParseError.missingField("action.path")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentLoopParseError.invalidField("action.path 不能为空")
        }
        return trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

// MARK: - Prompt 组装

public enum AgentLoopPrompt {

    public static func system(task: AgentTask, step: Int, maxSteps: Int) -> String {
        let frame = task.target.frame
        let frameText = String(
            format: "x=%.0f, y=%.0f, width=%.0f, height=%.0f",
            frame.origin.x, frame.origin.y, frame.width, frame.height
        )
        return """
        你是 Perch 的桌面操作代理，正在操作一台真实 Mac 上已经打开的一个窗口。你的操作会改动用户的真实数据，请保持最小改动、谨慎操作。

        目标窗口
        - 应用：\(task.target.appName)
        - 窗口标题：\(task.target.windowTitle.isEmpty ? "（无标题）" : task.target.windowTitle)
        - 位置与大小：\(frameText)

        用户任务：\(task.instruction)
        当前进度：第 \(step) 步（本次任务最多 \(maxSteps) 步）。

        输出协议（必须严格遵守）
        1. 整条回复必须且只能包含一个 JSON 对象。不要写解释、不要写 Markdown 标题；JSON 可以被代码块包裹，但代码块里只能有这一个对象。
        2. 每次只做一个动作，或者声明任务完成，二者只能选其一。
        3. 动作的完整集合（type 只能用下面这些）。示例里的 path 与坐标只是占位，不能照抄，必须换成你本轮在 AX 树里真实看到的 path：
           {"thought":"...","action":{"type":"click","path":"0/3/0"}}
           {"thought":"...","action":{"type":"setValue","path":"0/3/0","value":"要写入的文本"}}
           {"thought":"...","action":{"type":"typeText","text":"要输入的文本"}}
           {"thought":"...","action":{"type":"pressKey","key":"return","modifiers":["command"]}}
           {"thought":"...","action":{"type":"focusWindow","path":"0/3/0"}}
           {"thought":"...","action":{"type":"clickAtPoint","x":100,"y":200}}
           {"thought":"...","action":{"type":"openApp","name":"Safari"}}
        4. 任务完成时返回：{"done":true,"summary":"一句话说明你做了什么、结果如何"}。

        执行器行为（它决定了你该怎么选动作）
        - 执行器用的是真实的鼠标移动点击与真实的键盘输入，和人在用这台 Mac 一样；动作是否命中取决于真实屏幕状态与键盘焦点。
        - click 会真实移动鼠标并点在该元素可见区域的正中心，所以优先用 click + path；clickAtPoint 只在 AX 树里确实没有可用元素时才用。
        - setValue 与 typeText 都是以逐字符键盘输入的方式打到“当前焦点”上的，不会自动找输入框：先 focusWindow，或先 click 到目标输入框，确认焦点正确再输入。
        - 要覆盖输入框里已有的文本，先发 {"type":"pressKey","key":"a","modifiers":["command"]} 全选，再 typeText；不要指望 setValue 或 typeText 自动清空旧内容。
        - 每个动作执行后要等 0.1–0.3 秒界面动画与网络延迟，你才会拿到新的截图与 AX 树；不要假设动作瞬时完成，也不要因为“上一步看起来没生效”就重复同一个动作。

        动作规则
        - path 必须逐字来自本轮 AX 树里真实出现的元素路径（形如 0/2/1），绝不允许臆造、拼接或猜测路径；树里没有的元素不要点。
        - 优先用 click + path 命中控件（会点元素中心）；只有在 AX 树里确实找不到可点击元素时，才退化为 clickAtPoint 盲点坐标，且坐标要落在目标窗口的 frame 之内。
        - 需要让目标窗口回到前台、或担心点击落在遮挡物（浮层、其它窗口、菜单）上时，先用 focusWindow 把窗口激活，再继续操作。
        - thought 用一句中文说明你看到的现状与这一步的意图，方便用户跟踪进度。
        - 如果上一步动作失败，先按错误文本判断原因：path 失效就换本轮树里的新 path；点击没反应则多半是被遮挡或焦点不对，先 focusWindow 或先点目标控件再操作；不要重复同一个失败动作。
        - 如果任务已经完成，或继续操作会破坏用户数据，直接返回 done，并在 summary 里说明原因。
        """
    }

    public static func observation(axTree: String?, notes: [String], feedback: String?) -> String {
        var lines: [String] = ["【本轮观察】目标窗口的最新截图已附在这条消息里。"]
        if let feedback, !feedback.isEmpty {
            lines.append("【上一步反馈】\(feedback)")
        }
        if !notes.isEmpty {
            lines.append("【观察限制】\(notes.joined(separator: "；"))")
        }
        if let axTree, !axTree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let nodeCount = axTree.split(separator: "\n").count
            lines.append("【无障碍树】共 \(nodeCount) 行，每行开头就是该元素的 path：")
            lines.append(axTree)
        } else {
            lines.append("【无障碍树】本轮不可用：只能依据截图判断位置，用 clickAtPoint（坐标要落在窗口 frame 内），并先用 focusWindow 确保窗口在前台。")
        }
        lines.append("【下一步】只返回一个 JSON 对象。")
        return lines.joined(separator: "\n")
    }

    public static func stepSummary(thought: String, label: String, error: String?) -> String {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.isEmpty ? label : "\(clip(trimmed, 160))｜\(label)"
        if let error, !error.isEmpty {
            return "\(head)（失败：\(clip(error, 120))）"
        }
        return head
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
