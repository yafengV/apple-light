import SwiftUI

struct TaskSearchView: View {
  @Bindable var store: WorkspaceStore
  @State private var text = ""
  @State private var selectedID: String?
  @State private var pointerSelection = false
  @State private var catalog = TaskSearchCatalog()
  @State private var reload = UUID()
  @FocusState private var focus: Field?
  private enum Field { case query, cancel, retry }

  private var request: TaskSearchRequest {
    TaskSearchRequest(query: text, tasks: store.library.tasks, names: store.library.projectNames,
      notes: store.library.notes, branches: store.library.runBranches,
      runs: catalog.history + store.library.localRuns + store.runs)
  }
  private var selectable: [String] {
    guard !catalog.searching, catalog.resultsQuery == text else { return [] }
    return results.filter { store.canSelectTask($0.task) }.map(\.id)
  }
  private var selection: String? {
    if let selectedID, selectable.contains(selectedID) { return selectedID }
    return selectable.first
  }
  private var groups: [TaskSearchGroup] {
    TaskSearchPresentation.groups(catalog.results, query: text,
      pinnedOrder: store.library.sidebarItems(in: SidebarLayout.pinned).compactMap {
        if case .task(let id) = $0 { return id }; return nil
      })
  }
  private var results: [TaskSearchResult] { groups.flatMap(\.results) }
  var body: some View {
    SearchDialog(identifier: "task-search-dialog", cancel: cancel) {
      panel
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey, shortcuts: store.shortcuts)
      .frame(width: 0, height: 0))
    .task(id: reload) { await catalog.load(root: store.dataRoot, library: store.library) }
    .task(id: request) {
      await catalog.search(request)
    }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索任务、消息或分支…", text: Binding(get: { text }, set: { text = $0; selectedID = nil; pointerSelection = false }))
          .textFieldStyle(.plain).focused($focus, equals: .query).accessibilityLabel("搜索任务")
        Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
      }.padding(18)
      Divider()
      ScrollViewReader { reader in
        List(selection: Binding(get: { selection }, set: { value in
          if let value, selectable.contains(value) { selectedID = value }
        })) {
          ForEach(groups) { group in
            Section(group.title) {
              ForEach(group.results) { result in
                Button { choose(result.task) } label: {
                  TaskSearchResultRow(result: result, query: text, shortcut: results.firstIndex(where: { $0.id == result.id })
                    .flatMap { TaskSearchPresentation.shortcutCommand($0) }.map { store.shortcuts.label($0) })
                }.buttonStyle(.plain).disabled(catalog.searching || catalog.resultsQuery != text || !store.canSelectTask(result.task))
                  .searchResultPointer(enabled: !catalog.searching && catalog.resultsQuery == text && store.canSelectTask(result.task)) {
                    pointerSelection = true; selectedID = result.id
                  }
                  .listRowBackground(selection == result.id ? Color.primary.opacity(0.07) : Color.clear)
                  .accessibilityAddTraits(selection == result.id ? .isSelected : [])
                  .tag(result.id).id(result.id)
              }
            }
          }
        }.onChange(of: selection) { _, id in
          if !pointerSelection, let id { reader.scrollTo(id) }
        }.overlay {
          if catalog.results.isEmpty {
            if catalog.loading || catalog.searching { ProgressView("正在搜索…") }
            else { Text("没有匹配的任务").foregroundStyle(.secondary) }
          }
        }
      }
      if !catalog.historyErrors.isEmpty {
        HStack {
          Text("部分项目历史未能读取").help(catalog.historyErrors.joined(separator: "\n"))
          Spacer()
          Button("重试", action: retry).disabled(catalog.loading)
            .settingsActionFocus($focus, equals: .retry, activate: retry)
        }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
      }
      HStack {
        Text(catalog.loading ? "正在读取其他项目的历史…" : "包括所有项目及已归档任务")
        Spacer()
        Text("↑↓ 选择 · ↵ 打开 · esc 关闭")
      }.appFont(.caption).foregroundStyle(.secondary).padding(14)
    }
  }

  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    pointerSelection = false
    switch key {
    case .taskSlot(let index):
      guard results.indices.contains(index) else { return }
      choose(results[index].task)
    case .cancel: cancel()
    case .submit:
      if focus == .cancel { cancel() }
      else if focus == .retry { retry() }
      else if let result = results.first(where: { $0.id == selection }) { choose(result.task) }
    case .move(let delta): move(delta); focus = .query
    case .tab(let reverse):
      let fields: [Field] = !catalog.historyErrors.isEmpty && !catalog.loading
        ? [.query, .cancel, .retry] : [.query, .cancel]
      let index = fields.firstIndex(of: focus ?? .query) ?? 0
      focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
    }
  }
  private func retry() { focus = .query; reload = UUID() }
  private func cancel() {
    store.setOverlay(.taskSearch, presented: false)
    store.restoreOverlayFocus()
  }
  private func move(_ offset: Int) {
    guard !catalog.searching, catalog.resultsQuery == text else { return }
    selectedID = TaskSearchRequest.nextSelection(selection, ids: selectable, offset: offset)
  }
  private func choose(_ task: WorkspaceTask) {
    guard !catalog.searching, catalog.resultsQuery == text,
      let current = store.library.tasks.first(where: { $0.id == task.id }), store.canSelectTask(current) else { return }
    store.setOverlay(.taskSearch, presented: false)
    store.fileFocusAfterOverlay = nil
    store.searchDialogReturnFocus = nil
    store.selectTask(current)
  }
}
