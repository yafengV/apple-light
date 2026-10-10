import SwiftUI

struct ModelSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var draft = ModelConfiguration()
  @State private var realtimeModelDraft = ""
  @State private var key = ""
  @State private var status = ""
  @State private var connection = ModelConnectionTest()
  var body: some View {
    SettingsForm {
      SettingsSection("独立 API 服务") {
        SettingsTextField("基础地址", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
          .settingsSearchTarget(.apiURL)
        SettingsTextField("模型 ID", text: $draft.model, prompt: Text("由你的服务商提供"))
          .settingsSearchTarget(.modelID)
        SettingsTextField("实时语音模型 ID", text: $realtimeModelDraft,
          prompt: Text("支持 /realtime 的模型；留空关闭语音聊天"))
          .settingsSearchTarget(.voiceModel)
        SettingsMenuPicker("会话协议", selection: $draft.apiProtocol, options: [
          SettingsMenuOption(value: .chatCompletions, title: "Chat Completions"),
          SettingsMenuOption(value: .codexResponses, title: "Codex Core · Responses")
        ])
        SettingsSecureField("API Key", text: $key, prompt: Text("留空保留此地址已保存的密钥"))
          .settingsSearchTarget(.apiKey)
        if draft.apiProtocol == .chatCompletions {
          SettingsMenuPicker("推理强度", selection: $draft.reasoning,
            options: reasoningOptions.map {
              SettingsMenuOption(value: $0, title: AgentReasoningEfforts.titles[$0] ?? $0)
            })
            .settingsSearchTarget(.reasoning)
          SettingsToggle(title: "记录服务返回的 token 用量",
            description: "开启后请求流式接口返回权威 token 统计。若兼容服务不支持 stream_options，请关闭此项。",
            isOn: $draft.includeUsage)
            .settingsSearchTarget(.tokenUsage)
          Text("使用 OpenAI 兼容 Chat Completions 流式接口。发送图片需要服务和模型支持图片输入。")
            .appFont(.caption).foregroundStyle(.secondary)
        } else {
          Text("Codex Core 使用 /responses 流式接口。当前支持已连接项目的文字、图片、文本/PDF 附件会话、只读计划模式、目标模式、代码审查及已启用的 MCP 工具。连接测试只检查 /models，首条消息才会验证 /responses。")
            .appFont(.caption).foregroundStyle(.secondary)
          SettingsToggle(title: "服务支持托管网页搜索",
            description: "仅当此 /responses 服务接受 web_search 工具时开启。连接测试不会验证搜索能力。",
            isOn: $draft.supportsHostedWebSearch)
            .settingsSearchTarget(.hostedWebSearch)
        }
        Text("地址与模型保存在 ShipiOS，密钥保存在 macOS Keychain，并按服务地址隔离。")
          .appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Button("保存配置") { save() }
          Button(connection.testing ? "测试中…" : "测试连接") {
            guard save() else { return }
            connection.start(config: draft, keyDraft: key)
          }.disabled(connection.testing)
        }
        if !connection.status.isEmpty {
          Text(connection.status).appFont(.callout).textSelection(.enabled)
        } else if !status.isEmpty { Text(status).appFont(.callout).textSelection(.enabled) }
      }
      SettingsSection {
        Button("回复风格与自定义指令…") { store.requestSettingsPage(.personalization) }
      }
    }.settingsFormStyle().appSurface().onAppear {
      reloadDraft()
    }
    .onChange(of: draft) { _, _ in
      connection.invalidateIfChanged(config: draft, keyDraft: key)
      updateDirtyState()
    }
    .onChange(of: realtimeModelDraft) { _, _ in updateDirtyState() }
    .onChange(of: key) { _, _ in
      connection.invalidateIfChanged(config: draft, keyDraft: key)
      updateDirtyState()
    }
    .onChange(of: store.modelSettingsResetRequest) { _, _ in reloadDraft() }
    .onChange(of: store.settingsPage) { _, page in
      if page != .model { connection.cancel() }
      if page == .model && !store.modelSettingsDirty { reloadDraft() }
    }
    .onDisappear { connection.cancel() }
  }
  private func reloadDraft() {
    connection.cancel()
    draft = store.modelConfiguration
    realtimeModelDraft = store.voicePreferences.realtimeModelID
    key = ""
    status = ""
    store.modelSettingsDirty = false
  }
  private func updateDirtyState() {
    store.modelSettingsDirty = draft != store.modelConfiguration
      || realtimeModelDraft != store.voicePreferences.realtimeModelID || !key.isEmpty
  }
  @discardableResult private func save() -> Bool {
    connection.cancel()
    do {
      try draft.validateEndpoint()
      guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentFailure(message: "请填写模型 ID。")
      }
      if !key.isEmpty {
        try ModelKeychain.save(key, account: draft.credentialAccount)
        store.invalidateSkillModelMetadata(account: draft.credentialAccount)
        key = ""
      }
      try store.saveModelConfiguration(draft)
      var voicePreferences = store.voicePreferences
      voicePreferences.realtimeModelID = realtimeModelDraft
      voicePreferences.normalize()
      store.voicePreferences = voicePreferences
      store.modelSettingsDirty = false
      status = "已保存。你可以返回任务发送消息。"
      return true
    } catch {
      status = error.localizedDescription
      return false
    }
  }

  private var reasoningOptions: [String] {
    var options = AgentReasoningEfforts.available(advanced: store.library.enabledAdvancedReasoningEfforts)
    if !options.contains(draft.reasoning) { options.append(draft.reasoning) }
    return options
  }
}
