import SwiftUI

struct ModelSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var draft = ModelConfiguration()
  @State private var key = ""
  @State private var status = ""
  @State private var testing = false
  var body: some View {
    Form {
      Section("独立 API 服务") {
        TextField("基础地址", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
          .settingsSearchTarget(.apiURL)
        TextField("模型 ID", text: $draft.model, prompt: Text("由你的服务商提供"))
          .settingsSearchTarget(.modelID)
        SecureField("API Key", text: $key, prompt: Text("留空保留此地址已保存的密钥"))
          .settingsSearchTarget(.apiKey)
        SettingsMenuPicker("推理强度", selection: $draft.reasoning, options: [
          SettingsMenuOption(value: "", title: "服务默认"),
          SettingsMenuOption(value: "low", title: "低"),
          SettingsMenuOption(value: "medium", title: "中"),
          SettingsMenuOption(value: "high", title: "高")
        ]).settingsSearchTarget(.reasoning)
        SettingsToggle(title: "记录服务返回的 token 用量",
          description: "开启后请求流式接口返回权威 token 统计。若兼容服务不支持 stream_options，请关闭此项。",
          isOn: $draft.includeUsage)
          .settingsSearchTarget(.tokenUsage)
        Text("使用 OpenAI 兼容 Chat Completions 流式接口。地址与模型保存在 ShipiOS，密钥保存在 macOS Keychain，并按服务地址隔离。")
          .appFont(.caption).foregroundStyle(.secondary)
        Text("发送图片需要所选服务和模型支持图片输入。")
          .appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Button("保存配置") { save() }
          Button(testing ? "测试中…" : "测试连接") {
            guard save() else { return }
            testing = true
            Task {
              defer { testing = false }
              do {
                let key = try ModelKeychain.read(account: draft.credentialAccount)
                let count = try await ModelAPIClient().test(config: draft, key: key)
                status = "连接成功，服务返回 \(count) 个模型。"
              } catch { status = error.localizedDescription }
            }
          }.disabled(testing)
        }
        if !status.isEmpty { Text(status).appFont(.callout).textSelection(.enabled) }
      }
      Section {
        Button("回复风格与自定义指令…") { store.settingsPage = .personalization }
      }
    }.settingsFormStyle().appSurface().onAppear { draft = store.modelConfiguration }
  }
  @discardableResult private func save() -> Bool {
    do {
      _ = try draft.endpoint("chat/completions")
      guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentFailure(message: "请填写模型 ID。")
      }
      if !key.isEmpty {
        try ModelKeychain.save(key, account: draft.credentialAccount)
        key = ""
      }
      try store.saveModelConfiguration(draft)
      status = "已保存。你可以返回任务发送消息。"
      return true
    } catch {
      status = error.localizedDescription
      return false
    }
  }
}
