import SwiftUI

struct BrowserSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var showingClearConfirmation = false
  @State private var clearing = false
  @State private var includeHistory = true
  @State private var site = ""
  @State private var siteDecision = BrowserAccessDecision.allow

  private var entries: [BrowserHistoryEntry] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return store.library.browserHistory }
    return store.library.browserHistory.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.url.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    Form {
      Section {
        Picker("浏览器设置", selection: $store.browserSettingsSection) {
          ForEach(BrowserSettingsSection.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
      }
      switch store.browserSettingsSection {
      case .history: historyAndData
      case .downloads: downloads
      case .permissions: permissions
      }
    }.settingsFormStyle().appSurface()
      .confirmationDialog(
        "清除内置浏览器数据？", isPresented: $showingClearConfirmation,
        titleVisibility: .visible
      ) {
        Button("清除", role: .destructive) {
          clearing = true
          Task {
            await store.clearBrowserData(includeHistory: includeHistory)
            clearing = false
          }
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text(includeHistory ? "将清除 Cookie、缓存、网站存储和浏览历史。" : "将清除 Cookie、缓存和网站存储，保留浏览历史。")
      }
  }

  @ViewBuilder private var historyAndData: some View {
      Section("浏览历史") {
        TextField("搜索标题或网址", text: $query).settingsSearchTarget(.browserHistory)
        Text("访问过的完整网址会保存在 ShipiOS 独立数据目录中，可能包含网址查询参数。")
          .appFont(.caption)
          .foregroundStyle(.secondary)
        if entries.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "暂无浏览历史" : "没有匹配的历史记录",
            systemImage: "clock.arrow.circlepath")
        } else {
          ForEach(entries) { entry in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).lineLimit(1)
                Text(entry.url).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.visitedAt.formatted(date: .abbreviated, time: .shortened))
                  .appFont(size: 10).foregroundStyle(.tertiary)
              }
              Spacer()
              Button("打开") { store.openBrowserHistory(entry) }
              Button(role: .destructive) { store.removeBrowserHistory(entry.id) } label: {
                Image(systemName: "trash")
              }.help("删除这条历史记录")
            }
          }
        }
      }
      Section("浏览数据") {
        Text(store.workspace.browser.dataStore.isPersistent
          ? "内置浏览器使用与系统浏览器分开的 ShipiOS 资料。Cookie、缓存和网站存储会在应用重启后保留；历史记录保存在 ShipiOS 独立数据目录。"
          : "此隔离实例使用临时浏览资料。Cookie、缓存和网站存储只在本次 App 运行期间保留；历史记录保存在当前实例的数据目录。")
          .foregroundStyle(.secondary)
        Toggle("同时清除浏览历史", isOn: $includeHistory)
        Button("清除浏览数据…", role: .destructive) { showingClearConfirmation = true }.settingsSearchTarget(.browserClear)
          .disabled(clearing)
        if clearing { ProgressView("正在清除…").controlSize(.small) }
        if let error = store.browserSettingsError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Section("当前能力") {
        Text("当前支持独立标签、地址与历史、刷新、网页弹出窗口、页面截图与评论，以及真实文件下载。站点工具、页面样式调整与完整 CDP 访问仍需浏览器 Agent 控制层。")
          .foregroundStyle(.secondary)
      }
  }

  @ViewBuilder private var downloads: some View {
    Section("下载位置") {
      LabeledContent("文件夹") {
        Text(store.browserDownloadDirectory.path)
          .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
      }
      .settingsSearchTarget(.browserDownloadFolder)
      HStack {
        Button("选择文件夹…") { store.chooseBrowserDownloadFolder() }
        Button("使用系统默认") { store.useSystemBrowserDownloadFolder() }
          .disabled(store.browserDownloadPreferences.directory == nil)
      }
      SettingsToggle(
        title: "每次下载时询问保存位置",
        description: "关闭询问时，文件会保存到上方文件夹；同名文件会自动生成新的名称。",
        isOn: Binding(
          get: { store.browserDownloadPreferences.askWhereToSave },
          set: { store.setBrowserAskWhereToSave($0) })).settingsSearchTarget(.browserAskDownload)
      if let error = store.browserSettingsError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    Section("下载记录") {
      HStack {
        Text("记录保存在 ShipiOS 独立数据目录中。清除记录不会删除已下载的文件。")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("清除已完成记录") { store.clearFinishedBrowserDownloads() }
          .disabled(!store.browserDownloads.contains {
            $0.status != .preparing && $0.status != .downloading
          })
      }
      .settingsSearchTarget(.browserDownloadHistory)
      BrowserDownloadList(store: store)
    }
  }

  @ViewBuilder private var permissions: some View {
    Section("默认网站访问") {
      SettingsMenuPicker(
        "浏览器 Agent 首次访问网站时",
        description: "这些规则用于 Agent 控制网页时的访问授权。你在地址栏中手动打开网站不受影响。",
        selection: Binding(
          get: { store.browserPermissionPreferences.defaultDecision },
          set: { store.setBrowserDefaultAccess($0) }),
        options: BrowserAccessDecision.allCases.map { SettingsMenuOption(value: $0, title: $0.title) })
      .settingsSearchTarget(.browserDefaultAccess)
    }
    Section("添加网站规则") {
      TextField("example.com", text: $site).settingsSearchTarget(.browserAddRule)
      Picker("访问权限", selection: $siteDecision) {
        Text(BrowserAccessDecision.allow.title).tag(BrowserAccessDecision.allow)
        Text(BrowserAccessDecision.block.title).tag(BrowserAccessDecision.block)
      }.pickerStyle(.segmented)
      Button("添加规则") {
        if store.setBrowserSiteAccess(site, decision: siteDecision) { site = "" }
      }.disabled(site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    Section("网站规则") {
      if store.browserPermissionPreferences.sites.isEmpty {
        ContentUnavailableView("没有网站规则", systemImage: "checkmark.shield")
      } else {
        ForEach(store.browserPermissionPreferences.sites.keys.sorted(), id: \.self) { host in
          HStack {
            Text(host).textSelection(.enabled)
            Spacer()
            SettingsMenuPicker(
              "访问权限：\(host)",
              selection: Binding(
                get: { store.browserPermissionPreferences.sites[host] ?? .ask },
                set: { _ = store.setBrowserSiteAccess(host, decision: $0) }),
              options: BrowserAccessDecision.allCases.map { SettingsMenuOption(value: $0, title: $0.title) }
            ).labelsHidden().frame(width: 120)
            Button(role: .destructive) { store.removeBrowserSiteAccess(host) } label: {
              Image(systemName: "trash")
            }.help("删除网站规则")
          }
        }
      }
      if let error = store.browserSettingsError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }
}
