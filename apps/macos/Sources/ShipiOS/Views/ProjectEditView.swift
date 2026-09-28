import SwiftUI
import AppKit

struct ProjectEditView: View {
  let store: WorkspaceStore
  let request: ProjectEditRequest
  @State private var title: String
  @State private var folders: [String]
  @State private var primary: String
  @State private var error: String?
  @FocusState private var nameFocused: Bool

  init(store: WorkspaceStore, request: ProjectEditRequest) {
    self.store = store
    self.request = request
    _title = State(initialValue: request.title)
    _folders = State(initialValue: [request.primaryPath] + request.folders)
    _primary = State(initialValue: request.primaryPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("编辑项目").appFont(.title2, weight: .semibold)
      TextField("项目名称", text: $title).textFieldStyle(.roundedBorder)
        .focused($nameFocused).accessibilityLabel("项目名称")
      HStack {
        Text("文件夹").appFont(.headline)
        Spacer()
        Button("添加文件夹…", action: addFolders)
      }
      ScrollView {
        VStack(spacing: 0) {
          ForEach(Array(folders.enumerated()), id: \.element) { index, path in
            if index > 0 { Divider() }
            folderRow(path, primary: path == primary)
          }
        }
      }.frame(minHeight: 90, maxHeight: 280)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      if let error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("保存失败：\(error)")
      }
      HStack {
        Spacer()
        Button("取消") { store.editingProject = nil }.keyboardShortcut(.cancelAction)
        Button("保存", action: save).buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 510)
      .onAppear { nameFocused = true }
      .accessibilityIdentifier("project-edit")
  }

  private func folderRow(_ path: String, primary: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
          if primary { Text("主目录").appFont(.caption).foregroundStyle(.secondary) }
        }
        Text(path).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
          .textSelection(.enabled)
      }
      Spacer()
      if !primary {
        Button("设为主目录") {
          self.primary = path
          error = nil
        }.buttonStyle(.borderless)
          .accessibilityLabel("设为主目录：\(path)")
        Button {
          folders.removeAll { $0 == path }
          error = nil
        } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("移除文件夹")
          .accessibilityLabel("移除文件夹：\(path)")
      }
    }.padding(12)
  }

  private func addFolders() {
    guard let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "添加项目文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, store.editingProject?.id == request.id else { return }
      do {
        folders = try ProjectFolders.canonical(folders + panel.urls.map(\.path))
        error = nil
      } catch { self.error = error.localizedDescription }
    }
  }

  private func save() {
    do {
      try store.saveProjectEdit(request, title: title, folders: folders.filter { $0 != primary }, primary: primary)
      store.editingProject = nil
      Task { await store.applyPrimaryToNewTask() }
    } catch { self.error = error.localizedDescription }
  }
}
