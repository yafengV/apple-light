import SwiftUI

struct CommandPaletteView: View {
  @Bindable var store: WorkspaceStore
  var context: SearchDialogContext? = nil
  @FocusedValue(\.gitWorkflowCommands) private var gitCommands
  @State private var query = ""
  @State private var selectedID: String?
  @State private var catalog = TaskSearchCatalog()
  @State private var reload = UUID()
  @State private var cyclingSearchSections = false
  @State private var pointerSelection = false
  @State var themeMenu = ThemeCommandMenu()
  @FocusState private var focus: Field?
  private enum Field { case query, cancel, retry, gitRetry }
  private struct ResultGroup: Identifiable {
    let id: String
    let title: String
    var commands: [DesktopCommand] = []
    var tasks: [TaskSearchResult] = []
    var browsers: [CommandBrowserResult] = []
    var themes: [ThemeCommandItem] = []
  }
  private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var request: TaskSearchRequest {
    TaskSearchRequest(query: searchQuery,
      tasks: !themeMenu.entered && CommandMenuSearch.searchesTasks(query) ? store.library.tasks : [],
      names: store.library.projectNames, notes: store.library.notes, branches: store.library.runBranches,
      runs: catalog.history + store.library.localRuns + store.runs,
      includeContentResults: !themeMenu.entered && CommandMenuSearch.searchesContent(query))
  }
  private var matches: [DesktopCommand] {
    Self.matchingCommands(searchQuery, git: gitCommands, appearance: store.appearance)
      .filter { DesktopCommand.environmentActionSlot($0.id) == nil || commandEnabled($0.id) }
  }
  static func matchingCommands(_ query: String, git: GitWorkflowCommandContext?, appearance: AppearancePreferences? = nil) -> [DesktopCommand] {
    var matches = DesktopCommand.search(query: query)
    if let appearance {
      matches.removeAll { $0.id == "theme" }
      if ThemeCommandMenu.rootMatches(query, appearance: appearance) {
        matches.append(.theme)
      }
    }
    return matches.filter {
      !GitWorkflowCommandContext.owns($0.id) || git?.enabled($0.id) == true
    }
  }
  private var taskResults: [TaskSearchResult] {
    guard !themeMenu.entered, CommandMenuSearch.searchesTasks(query), !catalog.searching,
      catalog.resultsQuery == searchQuery else { return [] }
    return Array(catalog.results.prefix(TaskSearchPresentation.limit))
  }
  private var groups: [ResultGroup] {
    if themeMenu.entered {
      let rows = themeMenu.rows(query: query, appearance: store.appearance)
      return [.init(id: "theme-actions", title: "", themes: rows.filter { if case .preset = $0.action { return false }; return true }),
        ResultGroup(id: "theme-presets", title: "配色主题", themes: rows.filter { if case .preset = $0.action { return true }; return false })]
        .filter { !$0.themes.isEmpty }
    }
    var result: [ResultGroup] = []
    if searchQuery.isEmpty {
      let pinned = CommandMenuSearch.pinned(library: store.library,
        currentID: context?.currentTaskID ?? store.selectedTask?.id)
      if !pinned.isEmpty { result.append(.init(id: "pinned", title: "已置顶任务", tasks: pinned)) }
      let recent = CommandMenuSearch.recent(library: store.library, currentID: context?.currentTaskID ?? store.selectedTask?.id)
      if !recent.isEmpty { result.append(.init(id: "recent", title: "最近任务", tasks: recent)) }
      result.append(.init(id: "quick", title: "快捷操作", commands: matches.filter { ["new", "open"].contains($0.id) }))
      result += commandGroups(matches.filter { !["new", "open"].contains($0.id) })
    } else {
      result += commandGroups(matches)
      let browsers = CommandBrowserResult.search(context?.browserResults ?? store.commandBrowserTabs, query: query)
      if !browsers.isEmpty { result.append(.init(id: "browsers", title: "浏览器标签", browsers: browsers)) }
      if !taskResults.isEmpty { result.append(.init(id: "tasks", title: "任务", tasks: taskResults)) }
    }
    return result
  }
  private func commandGroups(_ commands: [DesktopCommand]) -> [ResultGroup] {
    DesktopCommandGroup.allCases.compactMap { group in
      let members = commands.filter { $0.group == group }
      let matches = members.filter { $0.id == "theme" } + members.filter { $0.id != "theme" }
      return matches.isEmpty ? nil : .init(id: "commands-\(group.rawValue)", title: group.title, commands: matches)
    }
  }
  private var selectableGroups: [[String]] {
    groups.map { group in
      group.themes.map(\.id) + group.commands.filter { commandEnabled($0.id) }.map { "command:" + $0.id }
        + group.browsers.filter { canOpenBrowser($0) }.map(\.id)
        + group.tasks.filter { canSelectTask($0.task) }.map { "task:" + $0.id }
    }.filter { !$0.isEmpty }
  }
  private var selectable: [String] { selectableGroups.flatMap { $0 } }
  private var selection: String? {
    if themeMenu.entered {
      if let id = themeMenu.selectedID, selectable.contains(id) { return id }
      return selectable.first
    }
    if let selectedID, selectable.contains(selectedID) { return selectedID }
    return selectable.first
  }

  var body: some View {
    SearchDialog(identifier: "command-search-dialog", cancel: cancel) {
      VStack(spacing: 0) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(themeMenu.entered ? "搜索主题…" : "搜索命令与任务…", text: Binding(get: { query }, set: {
            guard query != $0 else { return }
            query = $0; selectedID = nil; themeMenu.selectedID = nil; cyclingSearchSections = false; pointerSelection = false
          })).textFieldStyle(.plain).focused($focus, equals: .query).accessibilityLabel(themeMenu.entered ? "搜索主题" : "搜索命令与任务")
          Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
            .accessibilityElement(children: .combine).accessibilityLabel("取消")
        }.padding(18)
        Divider()
        ScrollViewReader { reader in
          List(selection: Binding(get: { selection }, set: { value in
            if let value, selectable.contains(value) { select(value) }
          })) {
            ForEach(groups) { group in
              if group.title.isEmpty {
                resultRows(group)
              } else {
                Section { resultRows(group) } header: {
                  Text(group.title).accessibilityLabel(group.title).accessibilityAddTraits(.isHeader)
                }
              }
            }
          }.onChange(of: selection) { _, id in if !pointerSelection, let id { reader.scrollTo(id) } }
            .overlay {
              if groups.isEmpty {
                if CommandMenuSearch.searchesTasks(query) && (catalog.loading || catalog.searching) {
                  ProgressView("正在搜索…")
                } else { Text("没有匹配的命令或任务").foregroundStyle(.secondary) }
              }
            }
        }
        if !themeMenu.entered, CommandMenuSearch.searchesContent(query), !catalog.historyErrors.isEmpty {
          HStack {
            Text("部分项目历史未能读取").help(catalog.historyErrors.joined(separator: "\n"))
            Spacer()
            Button("重试", action: retry).disabled(catalog.loading)
              .settingsActionFocus($focus, equals: .retry, activate: retry)
          }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
        }
        if !themeMenu.entered, let commands = gitCommands, commands.request.repository.root != nil {
          if commands.loading {
            ProgressView("正在检查 Git 命令…").controlSize(.small).padding(10)
          } else if let error = commands.error {
            HStack {
              Text("Git 状态未能完整读取").help(error)
              Spacer()
              Button("重新检查") { refreshGitCommands() }
                .settingsActionFocus($focus, equals: .gitRetry, activate: refreshGitCommands)
            }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
          }
        }
        Divider()
        HStack {
          Text("↑↓ 选择")
          Spacer()
          Text("↵ 打开 · esc 关闭")
        }.appFont(.caption).foregroundStyle(.secondary).padding(14)
      }
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey, shortcuts: store.shortcuts)
      .frame(width: 0, height: 0))
    .task { await gitCommands?.refresh() }
    .task(id: reload) { await catalog.load(root: store.dataRoot, library: store.library) }
    .task(id: request) { await catalog.search(request) }
  }

  @ViewBuilder private func resultRows(_ group: ResultGroup) -> some View {
    ForEach(group.themes) { item in themeRow(item) }
    ForEach(group.commands, id: \.paletteID) { item in commandRow(item) }
    ForEach(group.browsers) { result in browserRow(result) }
    ForEach(group.tasks, id: \.paletteID) { result in taskRow(result) }
  }
  private func commandRow(_ item: DesktopCommand) -> some View {
    let id = "command:" + item.id
    return Button { invoke(id) } label: {
      HStack {
        Label(item.title, systemImage: item.id == "theme" ? (store.appearance.isDark ? "moon" : "sun.max") : item.icon)
        if item.id == "theme" { Text(ThemeCommandMenu.rootDescription(store.appearance)).foregroundStyle(.secondary) }
        Spacer()
        Text(store.shortcuts.label(item.id)).appFont(.caption).foregroundStyle(.secondary)
        if item.id == "theme" { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
      }.padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!commandEnabled(item.id))
      .searchResultPointer(enabled: commandEnabled(item.id)) { selectFromPointer(id) }
      .listRowBackground(id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityElement(children: .ignore).accessibilityLabel(item.title)
      .accessibilityValue(store.shortcuts.label(item.id)).accessibilityIdentifier(id)
      .accessibilityAction { invoke(id) }
      .accessibilityAddTraits(id == selection ? .isSelected : []).tag(id).id(id)
  }
  private func resetSearch(focusQuery: Bool = true) {
    query = ""; selectedID = nil; cyclingSearchSections = false; pointerSelection = false
    focus = focusQuery ? .query : nil
  }
  private func themeRow(_ item: ThemeCommandItem) -> some View {
    Button { invoke(item.id) } label: {
      HStack {
        if let icon = item.icon { Image(systemName: icon).frame(width: 18) }
        Text(item.title)
        if let description = item.description { Text(description).foregroundStyle(.secondary) }
        Spacer()
        if let swatch = item.swatch { ThemeColorSwatch(swatch: swatch) }
        if item.selected { Image(systemName: "checkmark").foregroundStyle(.secondary) }
      }.padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .searchResultPointer(enabled: true) { selectFromPointer(item.id) }
      .listRowBackground(item.id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.action == .back ? "返回命令菜单" : item.title)
      .accessibilityValue([item.description ?? "", item.selected ? "已应用" : ""].filter { !$0.isEmpty }.joined(separator: "，"))
      .accessibilityIdentifier(item.id).accessibilityAction { invoke(item.id) }
      .accessibilityAddTraits(item.id == selection ? .isSelected : []).tag(item.id).id(item.id)
  }
  private func taskRow(_ result: TaskSearchResult) -> some View {
    let id = "task:" + result.id
    return Button { invoke(id) } label: {
      HStack {
        TaskSearchResultRow(result: result, query: searchQuery, shortcut: taskResults.firstIndex(where: { $0.id == result.id })
          .flatMap { TaskSearchPresentation.shortcutCommand($0) }.map { store.shortcuts.label($0) })
        if store.library.unreadTasks.contains(result.id) {
          Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
            .accessibilityLabel("未读")
        }
      }
    }.buttonStyle(.plain).disabled(!canSelectTask(result.task))
      .searchResultPointer(enabled: canSelectTask(result.task)) { selectFromPointer(id) }
      .listRowBackground(id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityElement(children: .ignore).accessibilityLabel(result.task.title)
      .accessibilityValue([result.projectTitle, result.task.archived ? "已归档" : "",
        store.library.unreadTasks.contains(result.id) ? "未读" : "", result.source ?? "", result.snippet ?? ""]
        .filter { !$0.isEmpty }.joined(separator: "，"))
      .accessibilityIdentifier(id).accessibilityAction { invoke(id) }
      .accessibilityAddTraits(id == selection ? .isSelected : []).tag(id).id(id)
  }
  private func browserRow(_ result: CommandBrowserResult) -> some View {
    Button { invoke(result.id) } label: {
      HStack {
        Image(systemName: "globe").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(result.title.isEmpty ? result.url : result.title).lineLimit(1)
            .help(result.title.isEmpty ? result.url : result.title)
          Text(result.url).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).help(result.url)
        }
        Spacer()
        Text(result.ownerTitle).appFont(.caption).foregroundStyle(.secondary)
          .lineLimit(1).frame(maxWidth: 110, alignment: .trailing).help(result.ownerTitle)
      }.padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!canOpenBrowser(result))
      .searchResultPointer(enabled: canOpenBrowser(result)) { selectFromPointer(result.id) }
      .listRowBackground(result.id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityElement(children: .ignore).accessibilityLabel(result.title.isEmpty ? result.url : result.title)
      .accessibilityValue([result.title.isEmpty ? "" : result.url, result.ownerTitle].filter { !$0.isEmpty }.joined(separator: "，"))
      .accessibilityIdentifier(result.id).accessibilityAction { invoke(result.id) }
      .accessibilityAddTraits(result.id == selection ? .isSelected : []).tag(result.id).id(result.id)
  }
  private func selectFromPointer(_ id: String) {
    guard selectable.contains(id) else { return }
    pointerSelection = true
    select(id)
  }
  private func select(_ id: String?) {
    if themeMenu.entered { themeMenu.selectedID = id } else { selectedID = id }
  }
  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    pointerSelection = false
    switch key {
    case .taskSlot(let index):
      guard taskResults.indices.contains(index) else { return }
      invoke("task:" + taskResults[index].id)
    case .cancel: cancel()
    case .submit:
      if focus == .cancel { cancel() }
      else if focus == .retry { retry() }
      else if focus == .gitRetry { refreshGitCommands() }
      else { invoke() }
    case .move(let delta):
      select(TaskSearchRequest.nextSelection(selection, ids: selectable, offset: delta))
      focus = .query
    case .tab(let reverse):
      let searchGroups = groups.compactMap { group -> [String]? in
        if group.id == "browsers" { return group.browsers.filter { canOpenBrowser($0) }.map(\.id) }
        if group.id == "tasks" { return group.tasks.filter { canSelectTask($0.task) }.map { "task:" + $0.id } }
        return nil
      }
      if let next = CommandSearchSections.next(selection, groups: searchGroups,
        continuing: cyclingSearchSections, reverse: reverse) {
        selectedID = next; cyclingSearchSections = true; focus = .query
        return
      }
      var fields: [Field] = [.query, .cancel]
      if !themeMenu.entered, CommandMenuSearch.searchesContent(query), !catalog.historyErrors.isEmpty, !catalog.loading { fields.append(.retry) }
      if !themeMenu.entered, let commands = gitCommands, !commands.loading, commands.error != nil { fields.append(.gitRetry) }
      let index = fields.firstIndex(of: focus ?? .query) ?? 0
      focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
    }
  }
  private func canOpenBrowser(_ result: CommandBrowserResult) -> Bool {
    context?.canOpenBrowser(result) ?? store.canOpenCommandBrowserTab(result)
  }
  private func commandEnabled(_ id: String) -> Bool {
    if id == "theme" { return store.libraryLoaded && !store.restoringLibrary }
    if GitWorkflowCommandContext.owns(id) { return gitCommands?.enabled(id) == true }
    return context?.commandEnabled(id) ?? store.paletteCommandEnabled(id)
  }
  private func canSelectTask(_ task: WorkspaceTask) -> Bool {
    context?.canSelectTask(task) ?? store.canSelectTask(task)
  }
  private func retry() { focus = .query; reload = UUID() }
  private func refreshGitCommands() {
    focus = .query
    Task { await gitCommands?.refresh() }
  }
  private func cancel() {
    themeMenu.back()
    resetSearch(focusQuery: false)
    if let context { context.cancel(); return }
    store.setOverlay(.commands, presented: false)
    store.restoreOverlayFocus()
  }
  private func invoke(_ id: String? = nil) {
    guard let id = id ?? selection, selectable.contains(id) else { return }
    if id.hasPrefix("theme:") {
      let returned = id == "theme:back"
      if themeMenu.perform(id, store: store, close: cancel), returned { resetSearch() }
      return
    }
    if id == "command:theme" { themeMenu.enter(); resetSearch(); return }
    if id.hasPrefix("command:") {
      let command = String(id.dropFirst(8))
      if GitWorkflowCommandContext.owns(command) {
        guard let commands = gitCommands, commands.enabled(command) else { return }
        cancel()
        commands.execute(command)
      } else if let context { context.execute(command) } else { store.executePaletteCommand(command) }
    }
    else if let result = groups.flatMap(\.browsers).first(where: { $0.id == id }) {
      if let context { context.selectBrowser(result); return }
      store.setOverlay(.commands, presented: false)
      store.fileFocusAfterOverlay = nil
      store.searchDialogReturnFocus = nil
      Task { await store.openCommandBrowserTab(result) }
    }
    else if let result = groups.flatMap(\.tasks).first(where: { "task:" + $0.id == id }),
      let task = store.library.tasks.first(where: { $0.id == result.id }), canSelectTask(task) {
      if let context { context.select(task); return }
      store.setOverlay(.commands, presented: false)
      store.fileFocusAfterOverlay = nil
      store.searchDialogReturnFocus = nil
      store.selectTask(task)
    }
  }
}

private extension DesktopCommand {
  var paletteID: String { "command:" + id }
}
private extension TaskSearchResult {
  var paletteID: String { "task:" + id }
}
