import SwiftUI

struct TaskSearchView: View {
  @Bindable var store: WorkspaceStore
  @State private var text = ""
  @State private var selectedID: String?
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
    catalog.results.filter { store.canSelectTask($0.task) }.map(\.id)
  }
  var body: some View {
    SearchDialog(identifier: "task-search-dialog", cancel: cancel) {
      panel
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey)
      .frame(width: 0, height: 0))
    .task(id: reload) { await catalog.load(root: store.dataRoot, library: store.library) }
    .task(id: request) {
      await catalog.search(request)
      guard !Task.isCancelled, catalog.resultsQuery == text else { return }
      if selectedID == nil || !selectable.contains(selectedID!) { selectedID = selectable.first }
    }
    .onChange(of: selectable) { _, ids in
      if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
    }
    .onChange(of: catalog.searching) { _, searching in
      if !searching && selectedID == nil { selectedID = selectable.first }
    }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索任务、消息或分支…", text: Binding(get: { text }, set: { text = $0; selectedID = nil }))
          .textFieldStyle(.plain).focused($focus, equals: .query).accessibilityLabel("搜索任务")
        Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
      }.padding(18)
      Divider()
      ScrollViewReader { reader in
        List(catalog.results) { result in
          Button { choose(result.task) } label: {
            HStack(alignment: .top) {
              Image(systemName: result.task.archived ? "archivebox" : "text.bubble").foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 4) {
                highlighted(result.task.title).lineLimit(1)
                highlighted(result.projectTitle).appFont(.caption).foregroundStyle(.secondary)
                if let snippet = result.snippet, let source = result.source {
                  HStack(alignment: .top, spacing: 6) {
                    Text(source).appFont(.caption).foregroundStyle(.secondary)
                    highlighted(snippet).appFont(.caption).lineLimit(3)
                  }
                }
              }
              Spacer()
              if result.task.archived { Text("已归档").appFont(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 6).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(catalog.searching || catalog.resultsQuery != text || !store.canSelectTask(result.task))
            .listRowBackground(selectedID == result.id ? Color.primary.opacity(0.07) : Color.clear)
            .id(result.id)
        }.onChange(of: selectedID) { _, id in
          if let id { reader.scrollTo(id) }
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
    switch key {
    case .cancel: cancel()
    case .submit:
      if focus == .cancel { cancel() }
      else if focus == .retry { retry() }
      else if let result = catalog.results.first(where: { $0.id == selectedID }) { choose(result.task) }
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
  private func highlighted(_ text: String) -> Text {
    var attributed = AttributedString(text)
    let query = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      var remaining = text.startIndex..<text.endIndex
      while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining),
        !range.isEmpty {
        if let start = AttributedString.Index(range.lowerBound, within: attributed),
          let end = AttributedString.Index(range.upperBound, within: attributed) {
          attributed[start..<end].backgroundColor = .yellow.opacity(0.35)
        }
        remaining = range.upperBound..<text.endIndex
      }
    }
    return Text(attributed)
  }
  private func move(_ offset: Int) {
    guard !catalog.searching, catalog.resultsQuery == text else { return }
    selectedID = TaskSearchRequest.nextSelection(selectedID, ids: selectable, offset: offset)
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
