import Foundation
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var modules: [PerchModule] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        modules = ModuleRegistry.makeModules()
        for module in modules { module.start() }

        // 菜单栏入口由 Pip 的状态项承担（设置 / 退出），这里不再单独建状态项。
        // 首次运行（还没有任何 API Key）把设置窗口顶上来，否则用户找不到入口。
        if AppEnvironment.shared.providers.availableKinds.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { AppMenuHost.shared.onSettingsRequested?() }
        }

        // 启动时不主动弹系统权限框：那会抢走指令输入面板的键盘焦点。
        // 权限由「Perch 设置与权限…」里的按钮触发并展示状态。
        if ProcessInfo.processInfo.environment["PERCH_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { AppMenuHost.shared.onSettingsRequested?() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for module in modules.reversed() { module.stop() }
    }
}

@main
enum PerchMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
