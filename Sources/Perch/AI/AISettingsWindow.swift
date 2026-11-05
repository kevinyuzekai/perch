import Foundation
import AppKit
import SwiftUI

@MainActor
public final class AISettingsWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private var model: AISettingsModel?

    public init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    public var isShowing: Bool { window?.isVisible ?? false }

    /// .accessory 应用要拿到键盘焦点必须临时切 .regular + activate + makeKeyAndOrderFront。
    public func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = AISettingsModel(env: env)
        let host = NSHostingView(rootView: AISettingsView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Perch · 设置"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        _ = window.setFrameAutosaveName("PerchSettingsWindow")

        model.onClose = { [weak self] _ in
            self?.window?.close()
        }

        self.model = model
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // 关闭即丢弃未保存编辑：模型只服务于本次展示。
        model = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    public func closeAndRelease() {
        window?.delegate = nil
        window?.close()
        window = nil
        model = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
