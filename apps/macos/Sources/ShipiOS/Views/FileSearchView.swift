import SwiftUI

struct FileSearchView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    WorkspaceFileSearchView(workspace: store.workspace, open: { path in
      store.showPane("files")
      store.workspace.selectFile(path)
      if let root = store.workspace.root { store.fileFocusAfterOverlay = (root, path) }
      dismiss()
    }, cancel: { dismiss() })
  }
}

/// Search UI is shared, but each caller owns the workspace and destination.
struct WorkspaceFileSearchView: View {
  @Bindable var workspace: DeveloperWorkspace
  let open: (String) -> Void
  let cancel: () -> Void
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var focused: Bool
  private var results: [String] {
    Array(
      workspace.files.filter {
        query.isEmpty || $0.localizedCaseInsensitiveContains(query)
      }.prefix(200))
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
        TextField("按路径搜索文件…", text: $query).textFieldStyle(.plain).focused($focused)
          .onSubmit { openSelected() }
          .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(0, results.count - 1))
            return .handled
          }
          .onKeyPress(.upArrow) {
            selected = max(0, selected - 1)
            return .handled
          }
        Button("取消", action: cancel).keyboardShortcut(.cancelAction)
      }.padding(18)
      Divider()
      if let error = workspace.filesError {
        HStack {
          Text(error).foregroundStyle(.orange).appFont(.caption)
          Spacer()
          Button("重试") { Task { await workspace.refreshFiles() } }.disabled(workspace.loading)
        }.padding(10)
      }
      if results.isEmpty, workspace.filesError == nil {
        Text(workspace.loading ? "正在读取文件…" : "没有匹配的文件")
          .foregroundStyle(.secondary).padding()
      }
      ScrollViewReader { reader in
        List(Array(results.enumerated()), id: \.element) { index, path in
          Button {
            open(path)
          } label: {
            Label(path, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain)
            .listRowBackground(index == selected ? Color.primary.opacity(0.08) : .clear)
            .accessibilityAddTraits(index == selected ? .isSelected : []).id(index)
        }.onChange(of: selected) { _, index in reader.scrollTo(index) }
      }
      Divider()
      HStack {
        Text("\(results.count) 个文件")
        Spacer()
        Text("↑↓ 选择 · ↵ 打开 · esc 关闭")
      }.appFont(.caption).foregroundStyle(.secondary).padding(14)
    }.frame(width: 640, height: 430)
      .onChange(of: query) { _, _ in selected = 0 }
      .onChange(of: results) { _, values in selected = min(selected, max(0, values.count - 1)) }
      .task(id: workspace.root) {
        query = ""
        selected = 0
        await Task.yield()
        guard !Task.isCancelled else { return }
        focused = true
        await workspace.refreshFiles()
      }
  }
  private func openSelected() {
    guard results.indices.contains(selected) else { return }
    open(results[selected])
  }
}
