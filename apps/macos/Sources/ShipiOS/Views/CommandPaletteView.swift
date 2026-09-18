import SwiftUI

struct CommandPaletteView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var selectedID: String?
  @State private var catalog = TaskSearchCatalog()
  @State private var reload = UUID()
  @State private var cyclingSearchSections = false
  @FocusState private var focus: Field?
  private enum Field { case query, cancel, retry }
  private struct ResultGroup: Identifiable {
    let id: String
    let title: String
    var commands: [DesktopCommand] = []
    var tasks: [TaskSearchResult] = []
    var browsers: [CommandBrowserResult] = []
  }
  private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var request: TaskSearchRequest {
    TaskSearchRequest(query: searchQuery,
      tasks: CommandMenuSearch.searchesTasks(query) ? store.library.tasks : [],
      names: store.library.projectNames, notes: store.library.notes, branches: store.library.runBranches,
      runs: catalog.history + store.library.localRuns + store.runs,
      includeContentResults: CommandMenuSearch.searchesContent(query))
  }
  private var matches: [DesktopCommand] {
    DesktopCommand.all.filter { searchQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(searchQuery) }
  }
  private var taskResults: [TaskSearchResult] {
    guard CommandMenuSearch.searchesTasks(query), !catalog.searching,
      catalog.resultsQuery == searchQuery else { return [] }
    return Array(catalog.results.prefix(TaskSearchPresentation.limit))
  }
  private var groups: [ResultGroup] {
    var result: [ResultGroup] = []
    if searchQuery.isEmpty {
      let recent = CommandMenuSearch.recent(library: store.library, currentID: store.selectedTask?.id)
      if !recent.isEmpty { result.append(.init(id: "recent", title: "最近任务", tasks: recent)) }
      result.append(.init(id: "quick", title: "快捷操作", commands: matches.filter { ["new", "open"].contains($0.id) }))
      result.append(.init(id: "commands", title: "命令", commands: matches.filter { !["new", "open"].contains($0.id) }))
    } else {
      if !matches.isEmpty { result.append(.init(id: "commands", title: "命令", commands: matches)) }
      let browsers = CommandBrowserResult.search(store.commandBrowserTabs, query: query)
      if !browsers.isEmpty { result.append(.init(id: "browsers", title: "浏览器标签", browsers: browsers)) }
      if !taskResults.isEmpty { result.append(.init(id: "tasks", title: "任务", tasks: taskResults)) }
    }
    return result
  }
  private var selectableGroups: [[String]] {
    groups.map { group in
      group.commands.filter { store.paletteCommandEnabled($0.id) }.map { "command:" + $0.id }
        + group.browsers.filter { store.canOpenCommandBrowserTab($0) }.map(\.id)
        + group.tasks.filter { store.canSelectTask($0.task) }.map { "task:" + $0.id }
    }.filter { !$0.isEmpty }
  }
  private var selectable: [String] { selectableGroups.flatMap { $0 } }
  private var selection: String? {
    if let selectedID, selectable.contains(selectedID) { return selectedID }
    return selectable.first
  }

  var body: some View {
    SearchDialog(identifier: "command-search-dialog", cancel: cancel) {
      VStack(spacing: 0) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("搜索命令与任务…", text: Binding(get: { query }, set: {
            query = $0; selectedID = nil; cyclingSearchSections = false
          })).textFieldStyle(.plain).focused($focus, equals: .query).accessibilityLabel("搜索命令与任务")
          Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
        }.padding(18)
        Divider()
        ScrollViewReader { reader in
          List {
            ForEach(groups) { group in
              Section(group.title) {
                ForEach(group.commands, id: \.paletteID) { item in commandRow(item) }
                ForEach(group.browsers) { result in browserRow(result) }
                ForEach(group.tasks, id: \.paletteID) { result in taskRow(result) }
              }
            }
          }.onChange(of: selection) { _, id in if let id { reader.scrollTo(id) } }
            .overlay {
              if groups.isEmpty {
                if CommandMenuSearch.searchesTasks(query) && (catalog.loading || catalog.searching) {
                  ProgressView("正在搜索…")
                } else { Text("没有匹配的命令或任务").foregroundStyle(.secondary) }
              }
            }
        }
        if CommandMenuSearch.searchesContent(query), !catalog.historyErrors.isEmpty {
          HStack {
            Text("部分项目历史未能读取").help(catalog.historyErrors.joined(separator: "\n"))
            Spacer()
            Button("重试", action: retry).disabled(catalog.loading)
              .settingsActionFocus($focus, equals: .retry, activate: retry)
          }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
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
    .task(id: reload) { await catalog.load(root: store.dataRoot, library: store.library) }
    .task(id: request) { await catalog.search(request) }
  }

  private func commandRow(_ item: DesktopCommand) -> some View {
    let id = "command:" + item.id
    return Button { invoke(id) } label: {
      HStack {
        Label(item.title, systemImage: item.icon)
        Spacer()
        Text(store.shortcuts.label(item.id)).appFont(.caption).foregroundStyle(.secondary)
      }.padding(.vertical, 6).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!store.paletteCommandEnabled(item.id))
      .listRowBackground(id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityAddTraits(id == selection ? .isSelected : []).id(id)
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
    }.buttonStyle(.plain).disabled(!store.canSelectTask(result.task))
      .listRowBackground(id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityAddTraits(id == selection ? .isSelected : []).id(id)
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
    }.buttonStyle(.plain).disabled(!store.canOpenCommandBrowserTab(result))
      .listRowBackground(result.id == selection ? Color.primary.opacity(0.08) : .clear)
      .accessibilityAddTraits(result.id == selection ? .isSelected : []).id(result.id)
  }
  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    switch key {
    case .taskSlot(let index):
      guard taskResults.indices.contains(index) else { return }
      invoke("task:" + taskResults[index].id)
    case .cancel: cancel()
    case .submit:
      if focus == .cancel { cancel() }
      else if focus == .retry { retry() }
      else { invoke() }
    case .move(let delta):
      selectedID = TaskSearchRequest.nextSelection(selection, ids: selectable, offset: delta)
      focus = .query
    case .tab(let reverse):
      let searchGroups = groups.compactMap { group -> [String]? in
        if group.id == "browsers" { return group.browsers.filter { store.canOpenCommandBrowserTab($0) }.map(\.id) }
        if group.id == "tasks" { return group.tasks.filter { store.canSelectTask($0.task) }.map { "task:" + $0.id } }
        return nil
      }
      if let next = CommandSearchSections.next(selection, groups: searchGroups,
        continuing: cyclingSearchSections, reverse: reverse) {
        selectedID = next; cyclingSearchSections = true; focus = .query
        return
      }
      let fields: [Field] = CommandMenuSearch.searchesContent(query) && !catalog.historyErrors.isEmpty && !catalog.loading
        ? [.query, .cancel, .retry] : [.query, .cancel]
      let index = fields.firstIndex(of: focus ?? .query) ?? 0
      focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
    }
  }
  private func retry() { focus = .query; reload = UUID() }
  private func cancel() {
    store.setOverlay(.commands, presented: false)
    store.restoreOverlayFocus()
  }
  private func invoke(_ id: String? = nil) {
    guard let id = id ?? selection, selectable.contains(id) else { return }
    if id.hasPrefix("command:") { store.executePaletteCommand(String(id.dropFirst(8))) }
    else if let result = groups.flatMap(\.browsers).first(where: { $0.id == id }) {
      store.setOverlay(.commands, presented: false)
      store.fileFocusAfterOverlay = nil
      store.searchDialogReturnFocus = nil
      Task { await store.openCommandBrowserTab(result) }
    }
    else if let result = groups.flatMap(\.tasks).first(where: { "task:" + $0.id == id }),
      let task = store.library.tasks.first(where: { $0.id == result.id }), store.canSelectTask(task) {
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
