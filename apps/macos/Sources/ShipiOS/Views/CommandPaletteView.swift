import SwiftUI

struct CommandPaletteView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var selectedID: String?
  @FocusState private var focus: Field?
  private enum Field { case query, cancel }
  private var matches: [DesktopCommand] {
    DesktopCommand.all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }
  private var selectable: [String] {
    matches.filter { store.paletteCommandEnabled($0.id) }.map(\.id)
  }
  private var selection: String? {
    if let selectedID, selectable.contains(selectedID) { return selectedID }
    return selectable.first
  }

  var body: some View {
    SearchDialog(identifier: "command-search-dialog", cancel: cancel) {
      VStack(spacing: 0) {
        HStack {
          Image(systemName: "command").foregroundStyle(.secondary)
          TextField("搜索命令…", text: Binding(get: { query }, set: { query = $0; selectedID = nil }))
            .textFieldStyle(.plain).focused($focus, equals: .query).accessibilityLabel("搜索命令")
          Button("取消", action: cancel).settingsActionFocus($focus, equals: .cancel, activate: cancel)
        }.padding(18)
        Divider()
        ScrollViewReader { reader in
          List(matches) { item in
            Button { invoke(item.id) } label: {
              HStack {
                Label(item.title, systemImage: item.icon)
                Spacer()
                Text(store.shortcuts.label(item.id)).appFont(.caption).foregroundStyle(.secondary)
              }.padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!store.paletteCommandEnabled(item.id))
              .listRowBackground(item.id == selection ? Color.primary.opacity(0.08) : .clear)
              .accessibilityAddTraits(item.id == selection ? .isSelected : []).id(item.id)
          }.onChange(of: selection) { _, id in if let id { reader.scrollTo(id) } }
            .overlay {
              if matches.isEmpty { Text("没有匹配的命令").foregroundStyle(.secondary) }
            }
        }
        Divider()
        HStack {
          Text("↑↓ 选择")
          Spacer()
          Text("↵ 执行 · esc 关闭")
        }.appFont(.caption).foregroundStyle(.secondary).padding(14)
      }
    }
    .background(SearchDialogKeyboardBridge(onReady: { focus = .query }, action: handleKey)
      .frame(width: 0, height: 0))
  }

  private func handleKey(_ key: SearchDialogKeyboardBridge.Key) {
    switch key {
    case .cancel: cancel()
    case .submit: if focus == .cancel { cancel() } else { invoke() }
    case .move(let delta):
      selectedID = TaskSearchRequest.nextSelection(selection, ids: selectable, offset: delta)
      focus = .query
    case .tab: focus = focus == .cancel ? .query : .cancel
    }
  }
  private func cancel() {
    store.setOverlay(.commands, presented: false)
    store.restoreOverlayFocus()
  }
  private func invoke(_ id: String? = nil) {
    guard let command = id ?? selection else { return }
    store.executePaletteCommand(command)
  }
}
