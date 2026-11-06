# Perch

把 MacBook 刘海变成投放台，并在刘海右边养一只会盯着你光标的小球 **Pip**。
把 Pip 拖到任意窗口上，说一句话，它就接管那个窗口连续操作直到做完。

> **两个必须知道的点**
> 1. 这个 App 会用你的真实鼠标和键盘去操作**别的 App**，执行前请确认目标窗口是对的；分身球上随时可以急停。
> 2. 它需要「辅助功能 + 屏幕录制」两项系统权限，这两个权限等于把整台 Mac 的输入交给它，只在你信任的前提下开。

## 安装

官方构建使用 Developer ID 签名并通过 Apple 公证，下载后直接双击即可。

首次打开会依次请求两项权限，全部允许后**重启一次 App**（macOS 要求重启才生效）。
若某项之前被拒绝过，去 系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制 手动勾选 Perch。

从源码构建见文末「构建」。

## 一次性设置

1. 启动后常驻菜单栏，无 Dock 图标
2. 点菜单栏的 Perch 图标 → **Perch 设置与权限…** → 粘贴一个 API Key（DeepSeek / ChatGPT / Grok / Anthropic 任选，key 存 Keychain）
3. 面板底部有 **退出 Perch**（本 App 无 Dock 图标，这是可靠的退出入口）；首次运行没有 Key 时该面板会自动弹出
4. 同一面板的权限区：
   - **辅助功能**（AI 要能读窗口结构并点击输入）→ 必须开
   - **屏幕录制**（AI 要看窗口截图）→ 必须开
   授权后重启一次 Perch（系统设置 → 隐私与安全性 → 辅助功能 / 屏幕录制 里勾选 Perch）。

## 用法一：刘海

- 鼠标移到刘海上 → 向下展开两个投放区
- 左：圆角正方形 = **AirDrop**（拖文件上去直接发）
- 右：圆角长方形 = **暂存**（文件复制进 `~/Library/Application Support/Perch/Staging`，
  默认 **5 分钟**后自动删除；可在设置里改；展开区底部可拖出到 Finder 或右键删除）

## 用法二：Pip

- 刘海右边那只白球（菜单栏项，**不覆盖菜单栏**），眼睛跟着光标转、会眨眼
- **按住球拖到任意窗口上松手** → 弹出指令框 → 输入要求 → Enter
- 该窗口右上角出现一个「分身」小球，显示进度；点分身可**急停**或关闭
- 全自动执行，默认最多 12 步；主球始终留在原位不动
- 单击球 → 菜单：**Perch 设置与权限… / 退出 Perch**
- 说明：球优先作为菜单栏状态项显示；启动 1.5s 后会自检系统是否真的把它画上了菜单栏，
  没画出来（少数系统/显示配置会这样）就自动退回「刘海右侧 26x22 浮层球」，交互完全一致

## 用法三：刘海展开区

- 鼠标移进刘海区域展开，**移出（含展开后的整个面板区域）0.2s 内自动收回**
- 面板右下角有「设置」齿轮与「退出」电源两个按钮

## AI 怎么动手

不是调 AX 接口改属性，而是**模拟人类**：
- 点击 = 鼠标分 2–3 段轨迹移到元素中心（±2pt 抖动）→ 停留 → 按下 → 抬起
- 打字 = 逐字符键码输入，节奏 35–90ms/字，约 2% 概率插入长停顿；先 cmd+a 再覆盖旧文本
- 只有当鼠标点击确实没反应（界面快照无变化 450ms）才回退到 AXPress

## 图标

图标是代码画的：`tools/make_icon.py`（PIL，超采样 4x）生成
`Resources/AppIcon-1024.png` 与 `Resources/AppIcon.iconset`，
再由 `iconutil` 打包成 `Resources/AppIcon.icns`，构建时拷进 App bundle。

```bash
python3 tools/make_icon.py
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
./build.sh
```

构图：深色 squircle + 顶部黑色菜单栏/刘海 + 刘海右边的眼球 Pip。

## 构建

```bash
./dev.sh            # 仅编译（沙盒必须走这个：内部重定向了 CLANG_MODULE_CACHE_PATH 并加 --disable-sandbox）
./build.sh          # 编译 + 打包签名 build/Perch.app
./dist.sh           # 签名 + 公证 + 打包 zip 与 dmg
```

需要 macOS 14+ 与 Swift 6；App 本身不含任何 API Key，模型费用由你自己的账号承担。
自行分发时需要一个 Developer ID 证书（Xcode → Settings → Accounts → Manage Certificates 可申请），
没有证书也能本地构建，只是签名退化为 ad-hoc。

并发编译加 `--scratch-path .build-<名字>` 避免 .build 锁冲突。

## 目录

| 目录 | 职责 |
|---|---|
| `Sources/Perch/Core/` | 共享契约、模型、权限、Keychain、stub |
| `Sources/Perch/Notch/` | 刘海几何、展开面板、拖放、AirDrop、暂存 |
| `Sources/Perch/Pip/` | 眼球渲染、光标跟随、窗口命中、分身、指令框 |
| `Sources/Perch/AI/` | OpenAI 兼容 / Anthropic 两套 wire format、Provider 注册、设置窗口 |
| `Sources/Perch/Agent/` | ScreenCaptureKit 截图、AX 树读取、AX/CGEvent 动作执行 |
| `Sources/Perch/AgentLoop/` | 规划-执行-观察循环、JSON 协议、急停 |
| `Sources/Perch/ModuleRegistry.swift` | 五个模块的装配点 |

调试开关：`PERCH_OPEN_SETTINGS=1` 启动时直接打开设置窗口。
