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
  @State private var setupPlatform = EnvironmentPlatform.all
  @State private var cleanupPlatform = EnvironmentPlatform.all
  @State private var showingSetupVariables = false
  @State private var pendingEnvironmentFile: String?
  @State private var creatingEnvironment = false
  @State private var reloadingEnvironment = false
  @State private var showingDiscardConfirmation = false

  private var managedSnapshot: ManagedEnvironmentSnapshot? {
    guard let path = store.project?.path else { return nil }
    return store.library.managedWorktrees.first(where: { $0.path == path })?.environment
  }

  private var setupScript: Binding<String> {
    Binding(get: {
      setupPlatform == .all ? store.worktreeSetupScript
        : store.setupPlatformScripts.script(for: setupPlatform)
    }, set: { value in
      if setupPlatform == .all { store.worktreeSetupScript = value }
      else {
        var scripts = store.setupPlatformScripts
        scripts.set(value, for: setupPlatform)
        store.setupPlatformScripts = scripts
      }
    })
  }

  private var cleanupScript: Binding<String> {
    Binding(get: {
      cleanupPlatform == .all ? store.worktreeCleanupScript
        : store.cleanupPlatformScripts.script(for: cleanupPlatform)
    }, set: { value in
      if cleanupPlatform == .all { store.worktreeCleanupScript = value }
      else {
        var scripts = store.cleanupPlatformScripts
        scripts.set(value, for: cleanupPlatform)
        store.cleanupPlatformScripts = scripts
      }
    })
  }

  var body: some View {
    Form {
      if let project = store.project {
        Section("当前项目") {
          LabeledContent("项目", value: store.library.projectTitle(project.path))
          Text(project.path).appFont(.caption).textSelection(.enabled)
          if let managedSnapshot {
            LabeledContent("任务环境", value: managedSnapshot.name)
            Text("此任务使用创建时保存的环境配置。新任务的环境请在来源项目中调整。")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        Section("本地环境") {
          Picker("环境", selection: Binding(
            get: { store.environmentFileName },
            set: { fileName in
              guard fileName != store.environmentFileName else { return }
              if store.environmentHasUnsavedChanges {
                pendingEnvironmentFile = fileName
                creatingEnvironment = false
                reloadingEnvironment = false
                showingDiscardConfirmation = true
              } else { Task { await store.selectSharedEnvironment(fileName) } }
            })) {
              if !store.environmentFiles.contains(where: { $0.fileName == store.environmentFileName }) {
                Text(store.environmentFileName).tag(store.environmentFileName)
              }
              ForEach(store.environmentFiles.filter { $0.error == nil }) { entry in
                Text(entry.title).tag(entry.fileName)
              }
            }
            .disabled(!store.connected || store.environmentSaving)
          TextField("环境名称", text: $store.environmentName)
          Text(".codex/environments/\(store.environmentFileName)")
            .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          HStack {
            Button("保存共享环境") { Task { await store.saveSharedEnvironment() } }
              .disabled(!store.connected || store.environmentSaving)
            Button("重新载入环境") {
              if store.environmentHasUnsavedChanges {
                pendingEnvironmentFile = nil
                creatingEnvironment = false
                reloadingEnvironment = true
                showingDiscardConfirmation = true
              } else { Task { await store.refreshSharedEnvironments() } }
            }
              .disabled(!store.connected || store.environmentSaving)
            Button("新建环境") {
              if store.environmentHasUnsavedChanges {
                pendingEnvironmentFile = nil
                creatingEnvironment = true
                reloadingEnvironment = false
                showingDiscardConfirmation = true
              } else { store.createSharedEnvironment() }
            }.disabled(!store.connected || store.environmentSaving)
          }
          ForEach(store.environmentFiles.filter { $0.error != nil }) { entry in
            Label("\(entry.fileName)：需要修复后才能选择", systemImage: "exclamationmark.triangle")
              .appFont(.caption).foregroundStyle(.secondary)
          }
          if !store.environmentStatus.isEmpty {
            Text(store.environmentStatus).appFont(.caption).foregroundStyle(.secondary)
          }
        }.disabled(managedSnapshot != nil)
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
        Section("工作树初始化") {
          Text("创建托管工作树后、首次发送任务前运行。命令在新工作树目录中执行。")
            .appFont(.caption).foregroundStyle(.secondary)
          Picker("平台", selection: $setupPlatform) {
            ForEach(EnvironmentPlatform.allCases) { platform in
              Text(platform.title).tag(platform)
            }
          }.pickerStyle(.segmented)
          TextEditor(text: setupScript)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
            .accessibilityLabel("\(setupPlatform.title) 工作树初始化脚本")
          Button("变量") { showingSetupVariables.toggle() }
            .popover(isPresented: $showingSetupVariables) {
              VStack(alignment: .leading, spacing: 8) {
                Text("初始化脚本环境变量").fontWeight(.semibold)
                LabeledContent("来源目录", value: "CODEX_SOURCE_TREE_PATH")
                LabeledContent("工作树目录", value: "CODEX_WORKTREE_PATH")
              }.padding(16).frame(minWidth: 330).textSelection(.enabled)
            }
          Button("保存初始化脚本") { Task { await store.saveSharedEnvironment() } }
        }.disabled(managedSnapshot != nil)
        Section("工作树清理") {
          Text("清理托管工作树前在来源项目目录运行；失败时保留工作树。")
            .appFont(.caption).foregroundStyle(.secondary)
          Picker("平台", selection: $cleanupPlatform) {
            ForEach(EnvironmentPlatform.allCases) { platform in
              Text(platform.title).tag(platform)
            }
          }.pickerStyle(.segmented)
          TextEditor(text: cleanupScript)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
            .accessibilityLabel("\(cleanupPlatform.title) 工作树清理脚本")
          Button("保存清理脚本") { Task { await store.saveSharedEnvironment() } }
        }.disabled(managedSnapshot != nil)
        Section("快捷操作") {
          Text("保存后可从任务顶部启动；每次操作都会在当前项目的新终端标签中运行。")
            .appFont(.caption).foregroundStyle(.secondary)
          ForEach($store.environmentActions) { $action in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                TextField("操作名称", text: $action.title)
                Picker("图标", selection: $action.symbol) {
                  Label("工具", systemImage: "hammer").tag("tool")
                  Label("运行", systemImage: "play.fill").tag("run")
                  Label("调试", systemImage: "ladybug").tag("debug")
                  Label("测试", systemImage: "checkmark.circle").tag("test")
                }.frame(width: 135)
                Button(role: .destructive) {
                  store.environmentActions.removeAll { $0.id == action.id }
                } label: { Image(systemName: "trash") }
                .accessibilityLabel("删除操作 \(action.title)")
              }
              Picker("运行平台", selection: $action.platform) {
                ForEach(EnvironmentPlatform.allCases) { platform in
                  Text(platform == .all ? "全部平台" : platform.title).tag(platform)
                }
              }.frame(maxWidth: 240)
              TextEditor(text: $action.script)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72)
                .accessibilityLabel("\(action.title) 脚本")
            }
          }
          Button("添加操作") { store.environmentActions.append(EnvironmentAction()) }
          Button("保存快捷操作") { Task { await store.saveSharedEnvironment() } }
        }.disabled(managedSnapshot != nil)
      } else {
        ContentUnavailableView("尚未打开项目", systemImage: "shippingbox", description: Text("打开项目后配置其本地构建环境。"))
      }
      Section("工作树环境") {
        Button("查看工作树设置…") { store.settingsPage = .worktrees }
        Text("新任务可单独选择环境；托管工作树保存创建时的脚本和快捷操作。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
    }.settingsFormStyle().appSurface()
      .confirmationDialog("放弃未保存的环境修改？", isPresented: $showingDiscardConfirmation) {
        Button("放弃修改并继续", role: .destructive) {
          if creatingEnvironment { store.createSharedEnvironment() }
          else if reloadingEnvironment { Task { await store.refreshSharedEnvironments() } }
          else if let fileName = pendingEnvironmentFile {
            Task { await store.selectSharedEnvironment(fileName) }
          }
          pendingEnvironmentFile = nil
          creatingEnvironment = false
          reloadingEnvironment = false
        }
        Button("取消", role: .cancel) {
          pendingEnvironmentFile = nil
          creatingEnvironment = false
          reloadingEnvironment = false
        }
      }
  }
}
