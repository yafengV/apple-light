import SwiftUI

struct AgentSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      Section("Agent 默认值") {
        LabeledContent("模型", value: store.modelConfiguration.model.isEmpty ? "尚未配置" : store.modelConfiguration.model).settingsSearchTarget(.agentModel)
        LabeledContent("推理强度", value: reasoningTitle).settingsSearchTarget(.agentReasoning)
        Button("配置模型与 API…") { store.settingsPage = .model }
      }
      Section("建议") {
        SettingsToggle(title: "显示建议提示", description: "在空白任务中根据当前项目提供可直接执行的建议。", isOn: Binding(
          get: { store.personalization.showSuggestedPrompts },
          set: { _ = store.saveSuggestedPrompts($0) }))
          .disabled(!store.personalizationLoaded).settingsSearchTarget(.agentSuggestions)
      }
      Section("运行边界") {
        Text("模型会话使用 ShipiOS 独立 API。自主编码工具循环、审批策略和沙箱策略将在 Codex Core 接入后出现在此页。")
          .foregroundStyle(.secondary)
      }
    }.settingsFormStyle().appSurface()
  }

  private var reasoningTitle: String {
    switch store.modelConfiguration.reasoning {
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case let value where !value.isEmpty: value
    default: "服务默认"
    }
  }
}

struct GitSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var branchPrefix = ""
  @State private var status = ""

  var body: some View {
    Form {
      Section("分支") {
        TextField("分支前缀", text: $branchPrefix, prompt: Text("codex/")).settingsSearchTarget(.branchPrefix)
        Text("从当前提交创建分支时自动填入此前缀。留空可关闭。")
          .appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Button("保存") { savePrefix() }
          Button("恢复默认") { branchPrefix = "codex/"; savePrefix() }
        }
        if !status.isEmpty { Text(status).appFont(.caption).foregroundStyle(.secondary) }
      }
      Section("推送") {
        SettingsToggle(title: "始终强制推送", description: "从 ShipiOS 推送时使用 --force-with-lease。", isOn: Binding(
          get: { store.library.gitPreferences.alwaysForcePush },
          set: { value in
            var preferences = store.library.gitPreferences
            preferences.alwaysForcePush = value
            status = store.saveGitPreferences(preferences)
              ? (value ? "已启用始终强制推送。" : "已关闭始终强制推送。")
              : (store.error ?? "保存失败，请重试。")
          })).settingsSearchTarget(.alwaysForcePush)
      }
      Section("Pull Request") {
        SettingsToggle(title: "创建草稿 PR", description: "创建 PR 时默认使用草稿状态。", isOn: Binding(
          get: { store.library.gitPreferences.createDraftPullRequests },
          set: { value in
            var preferences = store.library.gitPreferences
            preferences.createDraftPullRequests = value
            status = store.saveGitPreferences(preferences) ? "已保存 PR 创建方式。" : (store.error ?? "保存失败，请重试。")
          })).settingsSearchTarget(.createDraftPullRequests)
      }
      Section("工作树根目录") {
        Text(store.worktreeRoot.path).textSelection(.enabled).settingsSearchTarget(.gitWorktreeRoot)
        HStack {
          Button("选择文件夹…") { store.chooseWorktreeRoot() }
          Button("恢复默认目录") { store.setWorktreeRoot(nil) }
            .disabled(store.library.worktreeRoot == nil)
        }.disabled(store.busy)
        Button("查看工作树设置…") { store.settingsPage = .worktrees }
      }
      GitInstructionsView(store: store, kind: .commit)
      GitInstructionsView(store: store, kind: .pullRequest)
      Section("当前项目") {
        if let project = store.project {
          LabeledContent("目录", value: project.path)
          LabeledContent("Git", value: store.workspace.gitAvailable ? store.workspace.gitBranch : "未检测到仓库")
        } else {
          Text("打开项目后可查看 Git 状态。" ).foregroundStyle(.secondary)
        }
      }
    }.settingsFormStyle().appSurface()
      .onAppear { branchPrefix = store.library.gitPreferences.branchPrefix }
  }

  private func savePrefix() {
    var preferences = store.library.gitPreferences
    preferences.branchPrefix = branchPrefix
    if store.saveGitPreferences(preferences) {
      branchPrefix = store.library.gitPreferences.branchPrefix
      status = "已保存。"
    } else { status = store.error ?? "保存失败，请重试。" }
  }
}

struct CodeReviewSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      Section("本地代码审查") {
        SettingsMenuPicker("默认变更范围", selection: Binding(
          get: { store.library.gitPreferences.defaultReviewScope },
          set: { scope in
            var preferences = store.library.gitPreferences
            preferences.defaultReviewScope = scope
            store.saveGitPreferences(preferences)
          }), options: GitReviewScope.allCases.map { SettingsMenuOption(value: $0, title: $0.title) })
        .settingsSearchTarget(.reviewScope)
        SettingsToggle(title: "只读审查",
          description: "只读时隐藏暂存、撤销和提交操作，差异、历史提交、分支比较和评论仍可使用。", isOn: Binding(
          get: { store.library.gitPreferences.readOnlyReview },
          set: { readOnly in
            var preferences = store.library.gitPreferences
            preferences.readOnlyReview = readOnly
            store.saveGitPreferences(preferences)
          }))
        .settingsSearchTarget(.readOnlyReview)
        Button("打开当前项目审查") { store.openReviewFromSettings() }
          .disabled(store.project == nil || !store.workspace.gitAvailable)
      }
      Section("Pull Request 审查") {
        Text("自动 PR 审查需要代码托管连接。ShipiOS 当前不会伪造云端审查状态。")
          .foregroundStyle(.secondary)
        Button("查看连接…") { store.settingsPage = .connections }
      }
    }.settingsFormStyle().appSurface()
  }
}

struct LocalEnvironmentSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      if let project = store.project {
        Section("当前项目") {
          LabeledContent("项目", value: store.library.projectTitle(project.path))
          Text(project.path).appFont(.caption).textSelection(.enabled)
        }
        Section("构建环境") {
          TextField("容器", text: $store.container).settingsSearchTarget(.environmentContainer)
          TextField("Scheme", text: $store.scheme).settingsSearchTarget(.environmentScheme)
          SettingsMenuPicker("构建配置", selection: $store.configuration, options: [
            SettingsMenuOption(value: "Debug", title: "Debug"),
            SettingsMenuOption(value: "Release", title: "Release")
          ])
          .settingsSearchTarget(.environmentConfiguration)
          Button("保存项目环境") { store.saveProfile() }
          Text("这些值用于环境诊断和本地构建，并随项目保存在 ShipiOS 独立目录中。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      } else {
        ContentUnavailableView("尚未打开项目", systemImage: "shippingbox", description: Text("打开项目后配置其本地构建环境。"))
      }
      Section("工作树环境") {
        Button("查看工作树设置…") { store.settingsPage = .worktrees }
        Text("工作树会继承来源项目的容器、Scheme 和构建配置。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
    }.settingsFormStyle().appSurface()
  }
}
