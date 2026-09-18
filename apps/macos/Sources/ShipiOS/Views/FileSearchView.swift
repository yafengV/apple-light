import SwiftUI

struct FileSearchView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    WorkspaceFileSearchView(workspace: store.workspace, open: { path in
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
  let open: (String) -> Void
  let cancel: () -> Void
  @State private var query = ""
  @State private var selected = 0
  @State private var pointerSelection = false
  @FocusState private var focus: Field?
  private enum Field { case query, cancel, retry }
  private var results: [String] {
    Array(
      workspace.files.filter {
        query.isEmpty || $0.localizedCaseInsensitiveContains(query)
      }.prefix(200))
  }
  var body: some View {
    SearchDialog(identifier: "file-search-dialog", cancel: cancel) {
      panel
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey)
      .frame(width: 0, height: 0))
    .onChange(of: results) { _, values in selected = min(selected, max(0, values.count - 1)) }
    .task(id: workspace.root) { await workspace.refreshFiles() }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
        TextField("按路径搜索文件…", text: Binding(get: { query }, set: { query = $0; selected = 0; pointerSelection = false })).textFieldStyle(.plain).focused($focus, equals: .query)
          .accessibilityLabel("搜索文件")
        Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
      }.padding(18)
      Divider()
      if let error = workspace.filesError {
        HStack {
          Text(error).foregroundStyle(.orange).appFont(.caption)
          Spacer()
          Button("重试", action: retry).disabled(workspace.loading)
            .settingsActionFocus($focus, equals: .retry, activate: retry)
        }.padding(10)
      }
      if results.isEmpty, workspace.filesError == nil {
        Text(workspace.loading ? "正在读取文件…" : "没有匹配的文件")
          .foregroundStyle(.secondary).padding()
      }
      ScrollViewReader { reader in
        List(Array(results.enumerated()), id: \.element, selection: Binding<String?>(
          get: { results.indices.contains(selected) ? results[selected] : nil },
          set: { path in if let path, let index = results.firstIndex(of: path) { selected = index } })) { index, path in
          Button {
            open(path)
          } label: {
            Label(path, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .searchResultPointer { pointerSelection = true; selected = index }
            .listRowBackground(index == selected ? Color.primary.opacity(0.08) : .clear)
            .accessibilityAddTraits(index == selected ? .isSelected : []).tag(path).id(path)
        }.onChange(of: selected) { _, index in
          if !pointerSelection, results.indices.contains(index) { reader.scrollTo(results[index]) }
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
      let fields: [Field] = workspace.filesError != nil && !workspace.loading
        ? [.query, .cancel, .retry] : [.query, .cancel]
      let index = fields.firstIndex(of: focus ?? .query) ?? 0
      focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
    }
  }
  private func retry() {
    focus = .query
    Task { await workspace.refreshFiles() }
  }

  private func openSelected() {
    guard results.indices.contains(selected) else { return }
    open(results[selected])
  }
}
