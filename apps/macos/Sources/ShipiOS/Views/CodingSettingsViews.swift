import AppKit
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

private enum EnvironmentPage: Equatable {
  case projects, overview, editor
}

struct LocalEnvironmentSettingsView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var environment: EnvironmentSettingsSession
  @State private var page = EnvironmentPage.projects
  @State private var inheritedExpanded = false
  @State private var expandedCatalogInherited: Set<String> = []
  @State private var setupPlatform = EnvironmentPlatform.all
  @State private var cleanupPlatform = EnvironmentPlatform.all
  @State private var showingSetupVariables = false
  @State private var reloadingEnvironment = false
  @State private var returningToOverview = false
  @State private var showingDiscardConfirmation = false

  private var managedSnapshot: ManagedEnvironmentSnapshot? {
    guard let path = environment.projectPath else { return nil }
    return store.library.managedWorktrees.first(where: { $0.path == path })?.environment
  }

  private var setupScript: Binding<String> {
    Binding(get: {
      setupPlatform == .all ? environment.setupScript
        : environment.setupPlatforms.script(for: setupPlatform)
    }, set: { value in
      if setupPlatform == .all { environment.setupScript = value }
      else {
        var scripts = environment.setupPlatforms
        scripts.set(value, for: setupPlatform)
        environment.setupPlatforms = scripts
      }
    })
  }

  private var cleanupScript: Binding<String> {
    Binding(get: {
      cleanupPlatform == .all ? environment.cleanupScript
        : environment.cleanupPlatforms.script(for: cleanupPlatform)
    }, set: { value in
      if cleanupPlatform == .all { environment.cleanupScript = value }
      else {
        var scripts = environment.cleanupPlatforms
        scripts.set(value, for: cleanupPlatform)
        environment.cleanupPlatforms = scripts
      }
    })
  }

  var body: some View {
    Group {
      switch page {
      case .projects: projectList
      case .overview: overview
      case .editor: editor
      }
    }
    .task(id: store.settingsSearchRequest?.token) {
      if store.settingsSearchRequest?.result.page == .environments,
        let path = store.project?.path {
        await openEnvironmentProject(path)
        page = .editor
      }
    }
    .task(id: store.settingsPage) {
      if store.destination == .settings && store.settingsPage == .environments && page == .projects {
        await store.refreshEnvironmentCatalog()
      }
    }
    .onChange(of: page) { _, newPage in
      if newPage == .projects && store.destination == .settings && store.settingsPage == .environments {
        Task { await store.refreshEnvironmentCatalog() }
      }
    }
    .onAppear {
      honorEnvironmentRoute()
    }
    .onChange(of: store.environmentSettingsOpenProject) { _, shouldOpen in
      if shouldOpen && store.destination == .settings { honorEnvironmentRoute() }
    }
    .onChange(of: store.destination) { _, destination in
      if destination == .settings && store.environmentSettingsOpenProject {
        honorEnvironmentRoute()
      } else if destination == .settings && store.settingsPage == .environments && page == .projects {
        Task { await store.refreshEnvironmentCatalog() }
      }
    }
    .confirmationDialog("放弃未保存的环境修改？", isPresented: $showingDiscardConfirmation) {
      Button("放弃修改并继续", role: .destructive) {
        if returningToOverview {
          Task {
            await environment.load()
            page = .overview
          }
        }
        else if reloadingEnvironment { Task { await environment.refresh() } }
        clearPendingNavigation()
      }
      Button("取消", role: .cancel) { clearPendingNavigation() }
    }
  }

  private func clearPendingNavigation() {
    reloadingEnvironment = false
    returningToOverview = false
  }

  private func saveEnvironment(returnToOverview: Bool = false) async {
    guard await environment.save() else { return }
    if store.project?.path == environment.projectPath && store.connected {
      await store.refreshSharedEnvironments()
    }
    if returnToOverview && store.destination == .settings && store.settingsPage == .environments {
      page = .overview
    }
  }

  private func honorEnvironmentRoute() {
    guard store.environmentSettingsOpenProject else { return }
    let showEditor = store.environmentSettingsOpenEditor
    store.environmentSettingsOpenProject = false
    store.environmentSettingsOpenEditor = false
    guard let path = store.project?.path else { page = .projects; return }
    Task {
      await openEnvironmentProject(path)
      if showEditor { page = .editor }
    }
  }

  private var projectList: some View {
    Form {
      Section {
        HStack {
          Text("选择项目").appFont(.title2, weight: .semibold)
          Spacer()
          Button("添加项目") { chooseEnvironmentProject() }
            .disabled(environment.loading || environment.saving)
        }
        Text("本地环境决定项目工作树的初始化、清理和快捷操作。")
          .foregroundStyle(.secondary)
      }
      if store.library.orderedProjects.isEmpty {
        Section {
          ContentUnavailableView("还没有项目", systemImage: "folder",
            description: Text("添加项目后配置本地环境。"))
        }
      } else {
        Section("可用项目") {
          ForEach(store.library.orderedProjects, id: \.self) { path in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Button {
                  Task { await openEnvironmentProject(path) }
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: store.library.isPermanentWorktree(path)
                      ? "arrow.triangle.branch" : "folder")
                      .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(store.library.projectTitle(path)).foregroundStyle(.primary)
                      Text(path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                  }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                  .disabled(projectUnavailable(path))
                  .accessibilityLabel("打开项目环境：\(store.library.projectTitle(path))")
                Button {
                  Task { await openEnvironmentProject(path, createNew: true) }
                } label: { Image(systemName: "plus") }
                  .buttonStyle(.plain)
                  .disabled(projectUnavailable(path))
                  .accessibilityLabel("添加环境到 \(store.library.projectTitle(path))")
              }
              if let entries = store.environmentCatalog[path] {
                ForEach(entries.filter { !$0.inherited }) { entry in
                  catalogEnvironmentRow(path: path, entry: entry)
                }
                let inherited = entries.filter(\.inherited)
                if !inherited.isEmpty {
                  DisclosureGroup("继承环境（\(inherited.count)）", isExpanded: Binding(
                    get: { expandedCatalogInherited.contains(path) },
                    set: { expanded in
                      if expanded { expandedCatalogInherited.insert(path) }
                      else { expandedCatalogInherited.remove(path) }
                    })) {
                    ForEach(inherited) { entry in
                      catalogEnvironmentRow(path: path, entry: entry)
                    }
                  }
                }
              } else if let error = store.environmentCatalogErrors[path] {
                Text("环境读取失败：\(error)").appFont(.caption).foregroundStyle(.red)
              } else if store.environmentCatalogLoading {
                ProgressView("正在载入环境…").controlSize(.small)
              }
            }
          }
        }
      }
      if let error = store.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if !environment.connected && !environment.status.isEmpty {
        Text(environment.status).foregroundStyle(.red).textSelection(.enabled)
      }
    }.settingsFormStyle().appSurface()
  }

  private func catalogEnvironmentRow(path: String, entry: LocalEnvironmentEntry) -> some View {
    Button {
      Task { await openEnvironmentProject(path, selectionID: entry.id) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: entry.error == nil ? "shippingbox" : "exclamationmark.triangle")
          .foregroundStyle(entry.error == nil ? Color.secondary : Color.red)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name ?? entry.fileName).foregroundStyle(entry.error == nil ? Color.primary : Color.red)
          if entry.inherited {
            Text("来自 \(entry.sourceFolder) · \(entry.fileName)")
              .appFont(.caption).foregroundStyle(.secondary)
          } else if entry.name != nil {
            Text(entry.fileName).appFont(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }.padding(.leading, 24).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(projectUnavailable(path))
      .accessibilityLabel(entry.title)
  }

  private func projectUnavailable(_ path: String) -> Bool {
    environment.loading || environment.saving
  }

  private var overview: some View {
    Form {
      Section {
        Button("‹ 环境") { page = .projects }
          .buttonStyle(.plain)
        if let path = environment.projectPath {
          Text(environment.projectTitle).appFont(.title2, weight: .semibold)
          Text(path).appFont(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      if let managedSnapshot {
        Section("任务环境") {
          LabeledContent("名称", value: managedSnapshot.name)
          Text("此任务使用创建时保存的环境配置。新任务请在来源项目中调整。")
            .foregroundStyle(.secondary)
        }
      } else {
        Section("项目环境") {
          ForEach(environment.files.filter { !$0.inherited }) { entry in
            environmentRow(entry)
          }
          Button("新建本地环境") {
            environment.create()
            page = .editor
          }.disabled(!environment.connected || environment.saving)
        }
        let inherited = environment.files.filter(\.inherited)
        if !inherited.isEmpty {
          Section {
            DisclosureGroup("继承环境（\(inherited.count)）", isExpanded: $inheritedExpanded) {
              ForEach(inherited) { entry in environmentRow(entry) }
            }
          }
        }
        Section("当前环境") {
          LabeledContent("名称", value: environment.name)
          LabeledContent("配置文件", value: environment.fileName)
          if !environment.setupScript.isEmpty {
            LabeledContent("初始化脚本", value: environment.setupScript)
          }
          LabeledContent("快捷操作", value: "\(environment.actions.count) 个")
          Button(environment.exists ? "编辑本地环境" : "创建本地环境") {
            page = .editor
          }.disabled(!environment.connected)
        }
      }
      if !environment.status.isEmpty {
        Text(environment.status).appFont(.caption).foregroundStyle(.secondary)
      }
    }.settingsFormStyle().appSurface()
  }

  @ViewBuilder private func environmentRow(_ entry: LocalEnvironmentEntry) -> some View {
    Button {
      Task {
        await environment.select(entry.id)
        if environment.fileName == entry.id {
          page = entry.error == nil ? .overview : .editor
        }
      }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.name ?? entry.fileName)
            .foregroundStyle(entry.error == nil ? Color.primary : Color.red)
          Text(entry.inherited ? "来自 \(entry.sourceFolder) · \(entry.fileName)" : entry.fileName)
            .appFont(.caption).foregroundStyle(.secondary)
          if entry.error != nil {
            Text("需要修复").appFont(.caption).foregroundStyle(.red)
          }
        }
        Spacer()
        if entry.id == environment.fileName { Image(systemName: "checkmark") }
        else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!environment.connected)
      .accessibilityLabel(entry.title)
  }

  private func openEnvironmentProject(_ path: String, selectionID: String? = nil,
    createNew: Bool = false) async {
    if environment.hasUnsavedChanges,
      environment.projectPath != path || createNew || selectionID != nil {
      environment.status = "当前环境有未保存的修改，请先保存或放弃。"
      page = .editor
      return
    }
    if environment.projectPath != path || !environment.connected {
      await environment.open(path, title: store.library.projectTitle(path), executable: store.executable)
    }
    guard environment.connected, environment.projectPath == path else { page = .projects; return }
    if createNew { environment.create() }
    else if let selectionID { await environment.select(selectionID) }
    let needsEditor = createNew || selectionID.flatMap { selected in
      environment.files.first(where: { $0.id == selected })?.error
    } != nil
    page = needsEditor ? .editor : .overview
  }

  private func chooseEnvironmentProject() {
    let panel = NSOpenPanel()
    panel.title = "选择项目所在文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard let window = NSApp.keyWindow else { return }
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        store.library.visit(path)
        store.saveLibrary()
        await openEnvironmentProject(path)
      }
    }
  }

  private var editor: some View {
    Form {
      Section {
        Button("‹ \(environment.projectTitle.isEmpty ? "项目" : environment.projectTitle)") {
          if environment.hasUnsavedChanges {
            returningToOverview = true
            showingDiscardConfirmation = true
          } else { page = .overview }
        }.buttonStyle(.plain).disabled(environment.saving)
        Text("编辑本地环境").appFont(.title2, weight: .semibold)
      }
      if let path = environment.projectPath {
        Section("当前项目") {
          LabeledContent("项目", value: environment.projectTitle)
          Text(path).appFont(.caption).textSelection(.enabled)
          if let managedSnapshot {
            LabeledContent("任务环境", value: managedSnapshot.name)
            Text("此任务使用创建时保存的环境配置。新任务的环境请在来源项目中调整。")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        Section("本地环境") {
          TextField("环境名称", text: $environment.name)
          Text(environment.fileName.hasPrefix("/")
            ? environment.fileName : ".codex/environments/\(environment.fileName)")
            .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          HStack {
            Button(environment.saveConflict ? "放弃修改并重新载入" : "保存共享环境") {
              if environment.saveConflict { Task { await environment.refresh() } }
              else { Task { await saveEnvironment(returnToOverview: true) } }
            }
              .disabled(!environment.connected || environment.saving)
            Button("重新载入环境") {
              if environment.hasUnsavedChanges {
                reloadingEnvironment = true
                showingDiscardConfirmation = true
              } else { Task { await environment.refresh() } }
            }
              .disabled(!environment.connected || environment.saving)
          }
          if !environment.status.isEmpty {
            Text(environment.status).appFont(.caption)
              .foregroundStyle(environment.saveConflict ? .red : .secondary)
          }
        }.disabled(managedSnapshot != nil)
        if store.project?.path == path {
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
          Button("保存初始化脚本") { Task { await saveEnvironment() } }
            .disabled(environment.saveConflict)
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
          Button("保存清理脚本") { Task { await saveEnvironment() } }
            .disabled(environment.saveConflict)
        }.disabled(managedSnapshot != nil)
        Section("快捷操作") {
          Text("保存后可从任务顶部启动；每次操作都会在当前项目的新终端标签中运行。")
            .appFont(.caption).foregroundStyle(.secondary)
          ForEach($environment.actions) { $action in
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
                  environment.actions.removeAll { $0.id == action.id }
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
          Button("添加操作") { environment.actions.append(EnvironmentAction()) }
          Button("保存快捷操作") { Task { await saveEnvironment() } }
            .disabled(environment.saveConflict)
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
  }
}
