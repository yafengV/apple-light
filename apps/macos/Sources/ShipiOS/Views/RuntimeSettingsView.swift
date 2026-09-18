import AppKit
import SwiftUI

struct RuntimeSettingsView: View {
  @Bindable var store: WorkspaceStore
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue
  var body: some View {
    HStack(spacing: 0) {
      SettingsNavigationView(store: store)
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        ZStack {
          ForEach(SettingsNavigation.pages) { page in
            ScrollViewReader { proxy in
              content(page)
                .environment(\.settingsPageTitle, page.usesScrollingFormHeader ? page.title : nil)
                .environment(\.settingsSearchPresentation,
                  store.destination == .settings && store.settingsPage == page ? store.settingsSearchRequest : nil)
                .task(id: store.settingsSearchRequest?.token) {
                  let request = store.settingsSearchRequest
                  guard store.settingsPage == page, let request,
                    request.result.page == page, let field = request.result.field else { return }
                  // Subpage controls are inserted during this update; yield before resolving their IDs.
                  await Task.yield()
                  guard !Task.isCancelled, store.settingsSearchRequest == request,
                    store.settingsPage == page else { return }
                  proxy.scrollTo(field.id, anchor: .center)
                }
            }
              .opacity(store.settingsPage == page ? 1 : 0)
              .allowsHitTesting(store.settingsPage == page)
              .disabled(store.settingsPage != page)
              .accessibilityElement(children: .contain)
              .accessibilityHidden(store.settingsPage != page)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.frame(maxWidth: SettingsPageLayout.viewportWidth).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusSection()
    }.frame(maxWidth: .infinity, maxHeight: .infinity).appSurface()
      .onAppear { ComposerSendShortcut.migrate() }
      .onExitCommand { store.closeSettingsFromKeyboard() }
  }
  @ViewBuilder private func content(_ page: SettingsPage) -> some View {
    switch page {
    case .profile: ProfileSettingsView(store: store)
    case .model: ModelSettingsView(store: store)
    case .agent: AgentSettingsView(store: store)
    case .git: GitSettingsView(store: store)
    case .codeReview: CodeReviewSettingsView(store: store)
    case .environments: LocalEnvironmentSettingsView(store: store)
    case .usage: UsageSettingsView(store: store)
    case .general:
      Form {
        EditorSettingsSection(store: store)
        Section("输入") {
          Toggle("显示教育提示", isOn: $store.showEducationalTips)
            .settingsSearchTarget(.tips)
          Text("在输入框上方显示可关闭的功能提示。")
            .appFont(.caption).foregroundStyle(.secondary)
          SettingsMenuPicker("发送快捷键", selection: $sendShortcutRaw,
            options: ComposerSendShortcut.allCases.map {
              SettingsMenuOption(value: $0.rawValue, title: $0.title)
            })
          .settingsSearchTarget(.sendShortcut)
          Text(sendShortcut.explanation).foregroundStyle(.secondary)
          Toggle("纯文本编辑器", isOn: $store.composerPlainTextMode)
            .settingsSearchTarget(.plainText)
          Text("编写消息时，将代码、Markdown 和链接保留为纯文本；关闭自动代码块、列表续行和富链接。")
            .appFont(.caption).foregroundStyle(.secondary)
          Toggle("显示上下文窗口用量", isOn: $store.showContextUsageIndicator)
            .settingsSearchTarget(.contextUsage)
          Text("在主窗口和独立任务窗口的输入区显示最近一轮请求的输入 token。")
            .appFont(.caption).foregroundStyle(.secondary)
          Toggle("底部面板", isOn: $store.showBottomPanelControl)
            .settingsSearchTarget(.bottomPanel)
          Text("在应用标题栏显示底部面板布局控制；终端快捷键仍可直接打开底部终端。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Section("链接与无项目任务") {
          SettingsMenuPicker("打开网页链接", selection: $store.webLinkTarget,
            options: WebLinkTarget.allCases.map { SettingsMenuOption(value: $0, title: $0.title) })
          .settingsSearchTarget(.webLinks)
          Text("应用内浏览器会把回答中的 HTTP 和 HTTPS 链接作为当前任务的内容标签打开；邮件链接仍交给系统。")
            .appFont(.caption).foregroundStyle(.secondary)
          LabeledContent("无项目任务文件夹") {
            Text(store.projectlessWorkspaceRoot.path)
              .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
          }
          .settingsSearchTarget(.projectlessFolder)
          HStack {
            Button("更改…") { store.chooseProjectlessWorkspaceRoot() }
            Button("恢复默认") { store.setProjectlessWorkspaceRoot(nil) }
              .disabled(store.library.projectlessWorkspaceRoot == nil)
          }
          Text("每个无项目任务会在这里获得独立目录。该目录进入模型上下文，并作为回答中相对文件链接的安全根目录。")
            .appFont(.caption).foregroundStyle(.secondary)
          Toggle("弹出窗口默认从项目外开始", isOn: $store.popoutWindowProjectlessDefault)
            .settingsSearchTarget(.popoutScope)
          Text("新建弹出任务窗口时使用无项目范围。关闭后，新窗口继承当前项目；当前没有项目时仍使用无项目范围。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Section("追加消息") {
          SettingsSegmentedPicker(title: "模型运行时发送消息", selection: $store.followUpBehavior,
            options: [FollowUpBehavior.queue, .steer].map { SettingsSegmentOption(value: $0, title: $0.title) })
          .settingsSearchTarget(.followUp)
          Text(store.followUpBehavior.explanation).foregroundStyle(.secondary)
          if let error = store.generalSettingsError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          }
          Text("任务、草稿、归档与模型配置保存在 ShipiOS 独立目录中。")
            .foregroundStyle(.secondary)
        }
        Section("应用") {
          Toggle("在菜单栏中显示", isOn: $store.showInMenuBar)
            .accessibilityLabel("在菜单栏中显示 ShipiOS")
            .settingsSearchTarget(.menuBar)
          Text("主窗口关闭后，让 ShipiOS 保留在 macOS 菜单栏中。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Section("代码审查") {
          Picker("审查结果呈现方式", selection: Binding(
            get: { store.library.gitPreferences.reviewDelivery },
            set: { delivery in
              var preferences = store.library.gitPreferences
              preferences.reviewDelivery = delivery
              store.saveGitPreferences(preferences)
            })) {
            ForEach(ReviewDelivery.allCases) { delivery in
              Text(delivery.title).tag(delivery)
            }
          }.pickerStyle(.segmented)
          .settingsSearchTarget(.reviewDelivery)
          Text("尽可能在当前聊天中启动 /review，或启动单独的审查聊天。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Section("终端") {
          SettingsSegmentedPicker(title: "默认终端位置", selection: Binding(
            get: { store.library.defaultTerminalLocation },
            set: { store.setDefaultTerminalLocation($0) }), options: [
              SettingsSegmentOption(value: .bottom, title: "底部"),
              SettingsSegmentOption(value: .right, title: "右侧")
            ])
          .settingsSearchTarget(.terminalLocation)
          Text("工具栏终端按钮、命令菜单和固定终端恢复都会使用此位置。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Section("运行") {
          Toggle("运行时防止休眠", isOn: $store.preventIdleSleep)
            .settingsSearchTarget(.preventSleep)
          Text("任务执行期间阻止空闲休眠，结束后自动恢复。显示器仍可熄灭，手动休眠和合盖仍由系统处理。")
            .appFont(.caption).foregroundStyle(.secondary)
          if store.sleepPrevention.active {
            Label("正在防止空闲休眠", systemImage: "moon.zzz").foregroundStyle(.secondary)
          }
          if let error = store.sleepPrevention.error {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
            Button("重试") { store.updateSleepPrevention(force: true) }
          }
        }
        Section("插件") {
          Toggle("插件", isOn: $store.pluginsEnabled)
            .settingsSearchTarget(.enablePlugins)
          Text("允许 ShipiOS 使用已安装并启用的插件。关闭后，@插件、$技能候选和模型请求中的插件上下文立即停用。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }.settingsFormStyle().appSurface()
    case .appearance:
      AppearanceSettingsView(store: store)
    case .pets:
      PetSettingsView(store: store)
    case .personalization:
      PersonalizationSettingsView(store: store)
    case .memories:
      MemorySettingsView(store: store)
    case .shortcuts:
      ShortcutSettingsView(store: store)
    case .notifications:
      NotificationSettingsView(store: store)
    case .browser:
      BrowserSettingsView(store: store)
    case .computerUse:
      ComputerUseSettingsView(store: store)
    case .connections:
      ConnectionSettingsView(store: store)
    case .hooks:
      PluginComponentSettingsView(store: store, kind: .hooks)
    case .plugins, .mcpServers, .skills:
      PluginSettingsView(store: store)
    case .worktrees:
      WorktreeSettingsView(store: store)
    case .archived:
      ArchivedTasksSettingsView(store: store)
    case .runtime:
      Form {
        LabeledContent("Agent", value: store.connected ? "已连接" : "未连接").settingsSearchTarget(.runtimeAgent)
        LabeledContent("数据根目录") { Text(store.dataRoot.path).textSelection(.enabled) }.settingsSearchTarget(.runtimeRoot)
        if let directory = store.dataDirectory {
          LabeledContent("当前项目") { Text(directory.path).textSelection(.enabled) }
        }
        Text("本地 Agent 执行诊断和构建。模型会话使用独立 API；当前尚未接入 Codex Core 的自主编码工具循环。")
          .foregroundStyle(.secondary)
      }.settingsFormStyle().appSurface()
    }
  }
  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }
}
