import SwiftUI

struct FileWorkspaceView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  var taskID: String? = nil
  @State private var line = ""
  @State private var lineError = false
  @State private var showingConflict = false
  @State private var compactTreePresented = false
  @FocusState private var lineFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      if geometry.size.width < 620 {
        if workspace.selectedFile == nil {
          fileBrowser
        } else {
          ZStack(alignment: .trailing) {
            fileDetail(compact: true)
            if compactTreePresented {
              Color.black.opacity(0.12).contentShape(Rectangle())
                .onTapGesture { compactTreePresented = false }
              fileBrowser.frame(width: min(280, geometry.size.width * 0.78))
                .background(.regularMaterial).shadow(radius: 12)
            }
          }
        }
      } else {
        HSplitView {
          fileDetail(compact: false)
          if workspace.fileTreeVisible || workspace.selectedFile == nil {
            fileBrowser.frame(minWidth: 180, idealWidth: 230, maxWidth: 360)
          }
        }
      }
    }
    .onChange(of: workspace.selectedFile) { _, path in
      if path != nil { compactTreePresented = false }
    }
    .confirmationDialog("保存此文件的更改？", isPresented: Binding(
      get: { workspace.fileCloseRequest != nil },
      set: { if !$0 { workspace.fileCloseRequest = nil } }
    )) {
      Button("保存并关闭") {
        guard let path = workspace.fileCloseRequest else { return }
        Task {
          if await workspace.saveFileEdits(key: workspace.editorKey(for: path)) {
            workspace.fileCloseRequest = nil
            closeFile(path)
          }
        }
      }
      Button("放弃更改并关闭", role: .destructive) {
        if let path = workspace.fileCloseRequest { workspace.discardAndCloseFile(path) }
      }.disabled(workspace.fileCloseRequest.flatMap {
        workspace.fileEditorSessions[workspace.editorKey(for: $0)]?.saving
      } == true)
      Button("继续编辑", role: .cancel) { workspace.fileCloseRequest = nil }
    } message: {
      Text("当前内容尚未写入磁盘。")
    }
    .sheet(isPresented: $showingConflict) { conflictSheet }
    .overlay(alignment: .topTrailing) {
      if workspace.loading { ProgressView().controlSize(.small).padding(12).allowsHitTesting(false) }
    }
  }

  private var fileBrowser: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("筛选项目文件", text: $workspace.fileQuery).textFieldStyle(.roundedBorder)
        Button { Task { await workspace.refreshFiles() } } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).help("刷新文件列表").accessibilityLabel("刷新文件列表")
      }.padding(10)
      if let error = workspace.filesError {
        Text(error).foregroundStyle(.orange).appFont(.caption).padding(10)
      }
      List {
        ForEach(workspace.fileGroups) { group in
          if workspace.fileRoots.count > 1 {
            Section {
              fileTree(group)
            } header: {
              Label(group.root.lastPathComponent, systemImage: "folder")
                .help(group.root.path)
            }
          } else {
            fileTree(group)
          }
        }
      }.listStyle(.sidebar)
    }
  }

  @ViewBuilder private func fileDetail(compact: Bool) -> some View {
    if let file = workspace.selectedFile {
      VStack(spacing: 0) {
        fileTabs
        HStack {
          Button {
            if compact { compactTreePresented.toggle() }
            else { workspace.fileTreeVisible.toggle() }
          } label: { Image(systemName: "sidebar.left") }
            .help(compact ? (compactTreePresented ? "隐藏文件树" : "显示文件树")
              : (workspace.fileTreeVisible ? "隐藏文件树" : "显示文件树"))
            .accessibilityLabel(compact ? (compactTreePresented ? "隐藏文件树" : "显示文件树")
              : (workspace.fileTreeVisible ? "隐藏文件树" : "显示文件树"))
          Text(file).appFont(.caption).lineLimit(1).help(file)
          Spacer()
          if let editor = workspace.selectedFileEditor {
            if editor.saving { ProgressView().controlSize(.small) }
            Text(editor.saving ? "正在保存…" : editor.hasUnsavedChanges ? "未保存" : "已保存")
              .foregroundStyle(editor.hasUnsavedChanges ? Color.orange : Color.secondary)
            Button("保存") { Task { await workspace.saveSelectedFileEdits() } }
              .disabled(!editor.hasUnsavedChanges || editor.saving || editor.changedOnDisk != nil)
              .help("保存文件 ⌘S")
          }
          Button("跳转到行…") { workspace.showingFileLine = true }
            .disabled(workspace.fileLoading || workspace.fileError != nil).help("跳转到行 \(store.shortcuts.label("browser-address"))")
          Button("在编辑器中打开") { Task { await store.openProjectFile(file, in: workspace) } }
            .help("在\(store.preferredEditor.title)中打开")
        }.buttonStyle(.plain).appFont(.caption).padding(10)
        if let error = workspace.fileOpenError {
          Text(error).foregroundStyle(.orange).textSelection(.enabled).appFont(.caption)
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        if workspace.fileIsReadOnly, !workspace.fileLoading, workspace.fileError == nil {
          Text("大文件已以只读方式打开；编辑请使用外部编辑器。")
            .appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        if let editor = workspace.selectedFileEditor, let error = editor.error {
          HStack {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            if editor.changedOnDisk != nil {
              Button("比较并处理…") { showingConflict = true }
            } else {
              Button("重试保存") { Task { await workspace.saveSelectedFileEdits() } }
            }
          }.appFont(.caption).padding(.horizontal, 10).padding(.bottom, 8)
        }
        Divider()
        if workspace.showingFileLine { linePicker }
        if let error = workspace.fileError {
          HStack(alignment: .top) {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("重试") { workspace.selectFile(file) }
          }.appFont(.caption).padding(10)
        }
        ZStack {
          FileSourcePreview(store: store, workspace: workspace, taskID: taskID)
            .overlay(alignment: .topTrailing) {
              if workspace.fileFind.isPresented {
                FileFindBar(workspace: workspace).padding(12)
              }
            }
            .overlay { if workspace.fileLoading { ProgressView("正在读取文件…") } }
          if workspace.selectionEdit.isPresented,
            let request = workspace.selectionEdit.request,
            let proposal = workspace.selectionEdit.proposal,
            workspace.selectedFile == request.path,
            let selected = request.selectedText,
            !proposal.prefersInlineReview(selectedText: selected) {
            FileSelectionFullReviewView(workspace: workspace, request: request, proposal: proposal)
          }
        }.frame(maxHeight: .infinity)
      }
    } else {
      ContentUnavailableView("选择文件", systemImage: "doc.text",
        description: Text("从文件树中打开项目文件"))
    }
  }

  private var conflictSheet: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("文件在应用外发生更改").appFont(.title2, weight: .semibold)
      Text("比较两个版本后选择保留哪一份；再次保存前仍会检查磁盘是否又发生变化。")
        .foregroundStyle(.secondary)
      if let editor = workspace.selectedFileEditor,
        editor.changedOnDisk?.utf8.count ?? 0 > LocalWorkspaceService.maximumEditableTextBytes {
        Text("磁盘版本超过应用内编辑上限。请先复制需要保留的本地文本，再保留磁盘版本。")
          .foregroundStyle(.orange)
      }
      HStack(spacing: 12) {
        conflictText("当前编辑", workspace.selectedFileEditor?.text ?? "")
        conflictText("磁盘版本", workspace.selectedFileEditor?.changedOnDisk ?? "")
      }
      HStack {
        Button("保留磁盘版本") {
          workspace.discardSelectedFileEdits()
          showingConflict = false
        }
        Spacer()
        Button("取消") { showingConflict = false }
        Button("用当前编辑覆盖") {
          Task {
            if await workspace.useLocalFileEditsAfterConflict() { showingConflict = false }
          }
        }.buttonStyle(.borderedProminent)
          .disabled((workspace.selectedFileEditor?.changedOnDisk?.utf8.count ?? 0)
            > LocalWorkspaceService.maximumEditableTextBytes)
      }
    }.padding(20).frame(minWidth: 760, minHeight: 480)
  }

  private func conflictText(_ title: String, _ content: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).appFont(.headline)
      ScrollView {
        Text(content).appFont(.caption, design: .monospaced)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }.frame(maxWidth: .infinity)
  }

  private func fileTree(_ group: WorkspaceFileGroup) -> some View {
    OutlineGroup(WorkspaceFileNode.tree(group.paths.filter {
      workspace.fileQuery.isEmpty || $0.localizedCaseInsensitiveContains(workspace.fileQuery)
        || group.root.path.localizedCaseInsensitiveContains(workspace.fileQuery)
    }, root: group.root == workspace.fileRoots.first ? nil : group.root), children: \.children) { node in
      if node.children != nil {
        Label(node.title, systemImage: "folder").appFont(.caption)
          .contextMenu {
            Button("复制路径") { copyFilePath(node.path) }
          }
      } else {
        Button { workspace.selectFile(node.path); compactTreePresented = false } label: {
          Label(node.title, systemImage: "doc.text").appFont(.caption).lineLimit(1).help(node.path)
        }.buttonStyle(.plain)
          .contextMenu {
            Button("打开文件") { workspace.selectFile(node.path); compactTreePresented = false }
            Button("添加到聊天") { Task { await addFileToChat(node.path) } }
            Button("复制路径") { copyFilePath(node.path) }
            Divider()
            Button("在编辑器中打开") {
              Task { await store.openProjectFile(node.path, in: workspace) }
            }
          }
      }
    }
  }

  private func copyFilePath(_ path: String) {
    do {
      let url = try workspace.fileLocation(path).url
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.path, forType: .string)
    } catch { store.error = error.localizedDescription }
  }

  func addFileToChat(_ path: String) async {
    do {
      let url = try workspace.fileLocation(path).url
      let draft = taskID ?? store.draftKey
      await store.importDroppedFiles([url], draft: draft)
    } catch { store.error = error.localizedDescription }
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
              if workspace.fileEditorSessions[workspace.editorKey(for: path)]?.hasUnsavedChanges == true {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                  .accessibilityLabel("未保存")
              }
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
