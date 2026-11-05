import Foundation
import AppKit

/// 光标处弹出的紧凑指令面板：Enter 提交、Esc 取消。
final class PipCommandPanel: PipFloatingPanel {
    private static let size = NSSize(width: 360, height: 46)

    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let field = PipFirstMouseTextField()
    private let hint = NSTextField(labelWithString: "Enter 发送 / Esc 取消")
    private var outsideMonitor: Any?

    init() {
        super.init(contentSize: PipCommandPanel.size, acceptsKey: true)

        let background = PipCapsuleView(frame: NSRect(origin: .zero, size: PipCommandPanel.size))
        background.cornerRadius = 14
        background.autoresizingMask = [.width, .height]
        contentView = background

        let height = PipCommandPanel.size.height

        field.frame = NSRect(x: 16, y: (height - 24) / 2, width: 232, height: 24)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "想让 Pip 做什么？",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.42),
                         .font: NSFont.systemFont(ofSize: 14)]
        )
        field.delegate = self
        background.addSubview(field)

        hint.frame = NSRect(x: 254, y: (height - 14) / 2 + 1, width: 96, height: 14)
        hint.alignment = .right
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor(white: 1, alpha: 0.36)
        background.addSubview(hint)
    }

    /// 在给定的 AppKit 全局点附近弹出并聚焦。
    func present(at point: CGPoint) {
        field.stringValue = ""
        var origin = CGPoint(x: point.x - 26, y: point.y - PipCommandPanel.size.height / 2)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? PipCoordinates.primaryScreen
        if let visible = screen?.frame {
            let inset: CGFloat = 8
            origin.x = min(max(origin.x, visible.minX + inset), visible.maxX - PipCommandPanel.size.width - inset)
            origin.y = min(max(origin.y, visible.minY + inset), visible.maxY - PipCommandPanel.size.height - inset)
        }
        setFrameOrigin(origin)

        // 顺序很关键：必须先把 Perch 激活成前台 App，窗口才有可能成为 key window；
        // 反过来（先 makeKey 后 activate）在别的 App 前台时 key 会被激活过程覆盖掉，
        // 表现就是面板出来了、但按键进不去输入框。
        becomesKeyOnlyIfNeeded = false   // 面板一上屏就要成为 key window（needsPanelToBecomeKey 是私有的，用这个）
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)

        // 激活/窗口切换是异步的，下一轮 runloop 再兜一次底，确保光标确实落在输入框里。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            if !self.isKeyWindow { self.makeKey() }
            if self.field.currentEditor() == nil { self.makeFirstResponder(self.field) }
        }
        startOutsideMonitor()
    }

    func dismiss() {
        stopOutsideMonitor()
        field.stringValue = ""
        orderOut(nil)
    }

    private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        guard !text.isEmpty else { onCancel?(); return }
        onSubmit?(text)
    }

    private func cancel() {
        dismiss()
        onCancel?()
    }

    private func startOutsideMonitor() {
        stopOutsideMonitor()
        // 只监听其他 app 的点击（本进程事件不会进入 global monitor）。
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.cancel()
        }
    }

    private func stopOutsideMonitor() {
        if let monitor = outsideMonitor {
            NSEvent.removeMonitor(monitor)
            outsideMonitor = nil
        }
    }
}

extension PipCommandPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
