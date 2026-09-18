import SwiftUI

struct FileSearchView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    WorkspaceFileSearchView(workspace: store.workspace, executable: store.executable, open: { path in
      store.showPane("files")
      store.workspace.selectFile(path)
      if let root = store.workspace.root { store.fileFocusAfterOverlay = (root, path) }
      store.setOverlay(.fileSearch, presented: false)
    }, cancel: { store.setOverlay(.fileSearch, presented: false) })
  }
}

/// Search UI is shared, but each caller owns the workspace and destination.
struct WorkspaceFileSearchView: View {
  @Bindable var workspace: DeveloperWorkspace
  let executable: URL
  let open: (String) -> Void
  let cancel: () -> Void
  @State private var query = ""
  @State private var selected = 0
  @State private var pointerSelection = false
  @State private var catalog = WorkspaceFileSearchCatalog()
  @State private var retries = 0
  @State private var openError: String?
  @FocusState private var focus: Field?
  private enum Field { case query, cancel, retry }
  private var request: WorkspaceFileSearchRequest {
    .init(root: workspace.root, query: query, executable: executable, retry: retries)
  }
  private var results: [WorkspaceFileSearchResult] {
    catalog.request == request && !catalog.searching ? catalog.results : []
  }
  var body: some View {
    SearchDialog(identifier: "file-search-dialog", cancel: cancel) {
      panel
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey)
      .frame(width: 0, height: 0))
    .onChange(of: results) { _, values in selected = min(selected, max(0, values.count - 1)) }
    .task(id: request) { openError = nil; await catalog.search(request) }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索文件", text: Binding(get: { query }, set: { query = $0; selected = 0; pointerSelection = false })).textFieldStyle(.plain).focused($focus, equals: .query)
          .accessibilityLabel("搜索文件")
        Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
      }.padding(18)
      Divider()
      if let error = openError ?? (catalog.request == request ? catalog.error : nil) {
        HStack {
          Text(error).foregroundStyle(.orange).appFont(.caption)
          Spacer()
          Button("重试", action: retry).disabled(catalog.searching)
            .settingsActionFocus($focus, equals: .retry, activate: retry)
        }.padding(10)
      }
      HStack { Text("文件"); Spacer() }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 10)
      if results.isEmpty, catalog.error == nil {
        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "输入以搜索文件"
          : catalog.searching || catalog.request != request ? "正在搜索文件…" : "没有匹配的文件")
          .foregroundStyle(.secondary).padding()
      }
      ScrollViewReader { reader in
        List(Array(results.enumerated()), id: \.element.path, selection: Binding<String?>(
          get: { results.indices.contains(selected) ? results[selected].path : nil },
          set: { path in if let path, let index = results.firstIndex(where: { $0.path == path }) { selected = index } })) { index, result in
          Button {
            openResult(result)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: result.isDirectory ? "folder" : "doc.text")
              Text(result.title).lineLimit(1)
              if !result.directory.isEmpty { Text(result.directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
              Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain).help(result.path)
            .searchResultPointer { pointerSelection = true; selected = index }
            .listRowBackground(index == selected ? Color.primary.opacity(0.08) : .clear)
            .accessibilityAddTraits(index == selected ? .isSelected : []).tag(result.path).id(result.path)
        }.onChange(of: selected) { _, index in
          if !pointerSelection, results.indices.contains(index) { reader.scrollTo(results[index].path) }
        }
      }
      Divider()
      HStack {
        Text("\(results.count) 个文件")
        Spacer()
        Text("↑↓ 选择 · ↵ 打开 · esc 关闭")
      }.appFont(.caption).foregroundStyle(.secondary).padding(14)
    }
  }

  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    pointerSelection = false
    switch key {
    case .taskSlot: break // File search does not register task-result shortcuts.
    case .cancel: cancel()
    case .move(let delta):
      selected = min(max(0, selected + delta), max(0, results.count - 1))
      focus = .query
    case .submit:
      if focus == .cancel { cancel() }
      else if focus == .retry { retry() }
      else { openSelected() }
    case .tab(let reverse):
      let fields: [Field] = (catalog.error != nil || openError != nil) && !catalog.searching
        ? [.query, .cancel, .retry] : [.query, .cancel]
      let index = fields.firstIndex(of: focus ?? .query) ?? 0
      focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
    }
  }
  private func retry() {
    focus = .query
    retries += 1
  }

  private func openSelected() {
    guard results.indices.contains(selected) else { return }
    openResult(results[selected])
  }

  private func openResult(_ result: WorkspaceFileSearchResult) {
    guard result.isDirectory else { open(result.path); return }
    do {
      guard let root = workspace.root else { return }
      let directory = try result.directoryURL(root: root)
      guard NSWorkspace.shared.open(directory) else { throw AgentFailure(message: "无法在访达中打开目录，请重试。") }
      cancel()
    } catch { openError = error.localizedDescription }
  }
}
