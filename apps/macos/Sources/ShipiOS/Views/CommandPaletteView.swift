import SwiftUI

struct CommandPaletteView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var focused: Bool
  private var matches: [DesktopCommand] {
    DesktopCommand.all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "command").foregroundStyle(.secondary)
        TextField("搜索命令…", text: $query).textFieldStyle(.plain).focused($focused)
          .onSubmit { invoke() }
          .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(0, matches.count - 1))
            return .handled
          }
          .onKeyPress(.upArrow) {
            selected = max(0, selected - 1)
            return .handled
          }
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20)
      Divider()
      ScrollViewReader { reader in
        List(Array(matches.enumerated()), id: \.element.id) { index, item in
          Button {
            invoke(item.id)
          } label: {
            HStack {
              Label(item.title, systemImage: item.icon)
              Spacer()
              Text(store.shortcuts.label(item.id)).appFont(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(!store.commandEnabled(item.id))
            .listRowBackground(index == selected ? Color.primary.opacity(0.08) : .clear).id(index)
        }.onChange(of: selected) { _, index in reader.scrollTo(index) }
      }
      HStack {
        Text("↑↓ 选择")
        Spacer()
        Text("↵ 执行 · esc 关闭")
      }
      .appFont(.caption).foregroundStyle(.secondary).padding(14)
    }.frame(width: 560, height: 440)
      .onAppear { focused = true }.onChange(of: query) { _, _ in selected = 0 }
  }
  private func invoke(_ id: String? = nil) {
    guard let command = id ?? (matches.indices.contains(selected) ? matches[selected].id : nil),
      store.commandEnabled(command)
    else { return }
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.executeCommand(command) }
  }
}
