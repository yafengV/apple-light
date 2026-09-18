import SwiftUI

struct FileSearchView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var focused: Bool
  private var results: [String] {
    Array(
      store.workspace.files.filter {
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
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(18)
      Divider()
      if let error = store.workspace.filesError {
        Text(error).foregroundStyle(.orange).appFont(.caption).padding(10)
      }
      if results.isEmpty {
        Text(store.workspace.loading ? "正在读取文件…" : "没有匹配的文件")
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
      .task {
        focused = true
        await store.workspace.refreshFiles()
      }
  }
  private func openSelected() {
    guard results.indices.contains(selected) else { return }
    open(results[selected])
  }
  private func open(_ path: String) {
    store.showPane("files")
    store.workspace.selectFile(path)
    if let root = store.workspace.root { store.fileFocusAfterOverlay = (root, path) }
    dismiss()
  }
}
