import SwiftUI

enum ProjectPickerOption: Hashable, Identifiable {
  case project(String), projectless, addFolder

  var id: Self { self }

  static func options(in library: WorkspaceLibrary, query: String) -> [Self] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let projects = library.orderedProjects.filter { path in
      search.isEmpty || library.projectTitle(path).localizedStandardContains(search)
        || path.localizedStandardContains(search)
    }.map(Self.project)
    if search.isEmpty { return [.projectless] + projects + [.addFolder] }
    return projects + [.addFolder]
  }
}

struct ProjectPickerView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var selectedOption: ProjectPickerOption?
  @State private var pointerSelection = false
  @FocusState private var focus: Field?
  private enum Field { case query, cancel }

  private var options: [ProjectPickerOption] {
    ProjectPickerOption.options(in: store.library, query: query)
  }
  private var selection: ProjectPickerOption? {
    if let selectedOption, options.contains(selectedOption) { return selectedOption }
    if query.isEmpty, let path = store.project?.path {
      let current = ProjectPickerOption.project(path)
      if options.contains(current) { return current }
    }
    return options.first
  }

  var body: some View {
    SearchDialog(identifier: "project-picker-dialog", cancel: cancel) {
      VStack(spacing: 0) {
        HStack {
          Image(systemName: "folder").foregroundStyle(.secondary)
          TextField("搜索项目或路径…", text: Binding(get: { query }, set: {
            query = $0; selectedOption = nil; pointerSelection = false
          }))
          .textFieldStyle(.plain).focused($focus, equals: .query)
          .accessibilityLabel("搜索项目")
          Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
        }.padding(18)
        Divider()
        ScrollViewReader { reader in
          List(options, selection: Binding(get: { selection }, set: { selectedOption = $0 })) { option in
            Button { choose(option) } label: { row(option) }
              .buttonStyle(.plain)
              .searchResultPointer { pointerSelection = true; selectedOption = option }
              .listRowBackground(selection == option ? Color.primary.opacity(0.08) : .clear)
              .accessibilityAddTraits(selection == option ? .isSelected : [])
              .tag(option).id(option)
          }.onChange(of: selection) { _, option in
            if !pointerSelection, let option { reader.scrollTo(option) }
          }
        }
        Divider()
        HStack {
          Text("选择项目后打开其工作区")
          Spacer()
          Text("↑↓ 选择 · ↵ 打开 · esc 关闭")
        }.appFont(.caption).foregroundStyle(.secondary).padding(14)
      }
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey)
      .frame(width: 0, height: 0))
  }

  @ViewBuilder private func row(_ option: ProjectPickerOption) -> some View {
    HStack(spacing: 11) {
      switch option {
      case .projectless:
        Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
        Text("无项目")
      case .addFolder:
        Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
        Text("打开其他文件夹…")
      case .project(let path):
        Image(systemName: store.library.isPermanentWorktree(path) ? "arrow.triangle.branch" : "folder")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text(store.library.projectTitle(path)).lineLimit(1)
          Text(path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 0)
        if store.project?.path == path { Image(systemName: "checkmark").accessibilityLabel("当前项目") }
      }
      Spacer(minLength: 0)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6).contentShape(Rectangle())
  }

  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    pointerSelection = false
    switch key {
    case .taskSlot: break
    case .cancel: cancel()
    case .submit:
      if focus == .cancel { cancel() }
      else if let selection { choose(selection) }
    case .move(let delta):
      guard !options.isEmpty else { return }
      let index = selection.flatMap { options.firstIndex(of: $0) } ?? 0
      selectedOption = options[min(max(0, index + delta), options.count - 1)]
      focus = .query
    case .tab(let reverse): focus = reverse ? .cancel : (focus == .query ? .cancel : .query)
    }
  }

  private func cancel() {
    store.setOverlay(.projectPicker, presented: false)
    store.restoreOverlayFocus()
  }

  private func choose(_ option: ProjectPickerOption) {
    guard options.contains(option), store.presentedOverlay == .projectPicker, store.destination == .workspace,
      store.activeLocalRun == nil, !store.busy, store.libraryLoaded else { return }
    store.setOverlay(.projectPicker, presented: false)
    store.searchDialogReturnFocus = nil
    store.fileFocusAfterOverlay = nil
    switch option {
    case .project(let path): Task { await store.open(URL(fileURLWithPath: path)) }
    case .projectless: Task { await store.openProjectless() }
    case .addFolder: store.chooseProject()
    }
  }
}
