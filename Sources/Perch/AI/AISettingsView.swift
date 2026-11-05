import SwiftUI

@MainActor
struct AIProviderSection: View {
    @ObservedObject var row: AIProviderSettingsRow
    @ObservedObject var model: AISettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: row.hasUsableKey ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(row.hasUsableKey ? Color.green : Color.secondary)
                Text(row.kind.displayName).font(.headline)
                Text(row.kind.usesAnthropicWireFormat ? "/messages" : "/chat/completions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("API Key").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    SecureField("粘贴 \(row.kind.displayName) API Key", text: $row.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Model").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField(row.kind.defaultModel.isEmpty ? "模型名" : row.kind.defaultModel, text: $row.model)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Base URL").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField(row.kind.defaultBaseURL.isEmpty ? "https://…/v1" : row.kind.defaultBaseURL, text: $row.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                Button("测试连接") { model.runTest(row) }
                    .disabled(!row.hasUsableKey || row.testState.isRunning)
                    .help(row.hasUsableKey ? "发送一次 ping 请求（max_tokens=8）" : "请先填写或保存 API Key")

                if !row.hasUsableKey {
                    Text("未配置 Key，已禁用").font(.caption).foregroundStyle(.secondary)
                }
                if row.testState.isRunning {
                    ProgressView().controlSize(.small)
                }
                testResultText
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .opacity(row.hasUsableKey ? 1 : 0.85)
    }

    @ViewBuilder
    private var testResultText: some View {
        switch row.testState {
        case .idle:
            EmptyView()
        case .running:
            Text("测试中…").font(.caption).foregroundStyle(.secondary)
        case .success(let text):
            Text(text).font(.caption).foregroundStyle(.green).lineLimit(2)
        case .failure(let text):
            Text(text).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }
}

@MainActor
struct AISettingsView: View {
    @ObservedObject var model: AISettingsModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("也可从菜单栏的 Perch 图标重新打开本窗口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    generalSection
                    Divider()
                    ForEach(model.rows) { row in
                        AIProviderSection(row: row, model: model)
                        Divider()
                    }
                    permissionSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 660, height: 700)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通用").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("默认 Provider").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $model.defaultProvider) {
                        ForEach(AIProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200, alignment: .leading)
                }
                GridRow {
                    Text("暂存保留秒数").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("300", text: $model.stagingTTLText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("默认 300 秒，范围 5–86400").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("权限").font(.headline)
                Spacer()
                Button("刷新") { model.refreshPermissions() }
                    .buttonStyle(.link)
            }

            permissionRow(title: "辅助功能",
                          granted: model.hasAccessibility,
                          onRequest: { model.requestAccessibility() },
                          onOpen: { model.openAccessibilitySettings() })

            permissionRow(title: "屏幕录制",
                          granted: model.hasScreenRecording,
                          onRequest: { model.requestScreenRecording() },
                          onOpen: { model.openScreenRecordingSettings() })

            Text("授权后需重启 Perch 才能完全生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(title: String,
                               granted: Bool,
                               onRequest: @escaping () -> Void,
                               onOpen: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title).frame(width: 80, alignment: .leading)
            Text(granted ? "已授权" : "未授权")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("请求授权", action: onRequest).disabled(granted)
            Button("打开系统设置", action: onOpen)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("退出 Perch") { NSApp.terminate(nil) }
                .help("退出 Perch（.accessory 应用无 Dock 图标，这里是退出入口）")
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button("取消") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("保存并关闭") { model.saveAndClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
