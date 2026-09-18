import SwiftUI

struct FileWorkspaceView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  @State private var line = ""
  @State private var lineError = false
  @FocusState private var lineFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("筛选项目文件", text: $workspace.fileQuery).textFieldStyle(.roundedBorder)
        Button { Task { await workspace.refreshFiles() } } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).help("刷新文件列表").accessibilityLabel("刷新文件列表")
      }.padding(10)
      if let error = workspace.filesError {
        Text(error).foregroundStyle(.orange).appFont(.caption).padding(10)
      }
      if workspace.selectedFile != nil { fileTabs }
      List {
        OutlineGroup(WorkspaceFileNode.tree(workspace.files.filter {
          workspace.fileQuery.isEmpty || $0.localizedCaseInsensitiveContains(workspace.fileQuery)
        }), children: \.children) { node in
          if node.children != nil {
            Label(node.title, systemImage: "folder").appFont(.caption)
          } else {
            Button { workspace.selectFile(node.path) } label: {
              Label(node.title, systemImage: "doc.text").appFont(.caption).lineLimit(1).help(node.path)
            }.buttonStyle(.plain)
          }
        }
      }.frame(minHeight: 90, idealHeight: 180, maxHeight: workspace.selectedFile == nil ? .infinity : 180)
      if let file = workspace.selectedFile {
        HStack {
          Text(file).appFont(.caption).lineLimit(1).help(file)
          Spacer()
          Button("跳转到行…") { workspace.showingFileLine = true }
            .disabled(workspace.fileLoading || workspace.fileError != nil).help("跳转到行 \(store.shortcuts.label("browser-address"))")
          Button("打开") {
            if let root = workspace.root { Task { await store.openProjectFile(file, root: root) } }
          }
        }.buttonStyle(.plain).appFont(.caption).padding(10)
        Divider()
        if workspace.showingFileLine { linePicker }
        if let error = workspace.fileError {
          HStack(alignment: .top) {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("重试") { workspace.selectFile(file) }
          }.appFont(.caption).padding(10)
        }
        FileSourcePreview(store: store, workspace: workspace).frame(maxHeight: .infinity)
          .overlay { if workspace.fileLoading { ProgressView("正在读取文件…") } }
      }
    }.overlay(alignment: .topTrailing) {
      if workspace.loading { ProgressView().controlSize(.small).padding(12).allowsHitTesting(false) }
    }
  }

  private var fileTabs: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 2) {
          ForEach(workspace.openFiles, id: \.self) { path in
            HStack(spacing: 6) {
              Button { workspace.selectFile(path) } label: {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).frame(maxWidth: 160)
              }.buttonStyle(.plain).help(path)
                .accessibilityLabel("文件标签：\(path)")
                .accessibilityAddTraits(workspace.selectedFile == path ? .isSelected : [])
              Button { closeFile(path) } label: { Image(systemName: "xmark").appFont(size: 9) }
                .buttonStyle(.plain).help("关闭 \(path)").accessibilityLabel("关闭文件：\(path)")
            }.padding(8)
              .background(workspace.selectedFile == path ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6)).id(path)
          }
        }
      }.scrollIndicators(.hidden)
        .onChange(of: workspace.selectedFile) { _, path in if let path { proxy.scrollTo(path) } }
        .onAppear { if let path = workspace.selectedFile { proxy.scrollTo(path) } }
    }.appFont(.caption).padding(5)
  }

  private var linePicker: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        TextField("行号", text: $line).textFieldStyle(.roundedBorder).focused($lineFocused)
          .onSubmit { lineError = !workspace.jumpToFileLine(line) }
          .onExitCommand { cancelLine() }
        Button("跳转") { lineError = !workspace.jumpToFileLine(line) }
        Button("取消") { cancelLine() }
      }
      if lineError { Text("请输入文件中存在的行号。").foregroundStyle(.orange).appFont(.caption) }
    }.padding(10).task { line = ""; lineError = false; lineFocused = true }
  }
  private func cancelLine() {
    workspace.showingFileLine = false
    workspace.fileFocusRequest = UUID()
  }
  private func closeFile(_ path: String) {
    if workspace === store.workspace { store.closeFileTab(path) }
    else { workspace.closeFile(path) }
  }
}
