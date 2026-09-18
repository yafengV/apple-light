import SwiftUI

struct ConversationFindBar: View {
  @Bindable var store: WorkspaceStore
  @FocusState private var focused: Bool
  var body: some View {
    HStack {
      Image(systemName: "magnifyingglass")
      TextField("在当前任务中查找", text: $store.findText).textFieldStyle(.roundedBorder).focused($focused)
        .onSubmit { store.moveFindMatch(1) }
        .onChange(of: store.findText) { _, _ in store.findIndex = 0 }
      Text(
        store.findMatches.isEmpty
          ? "0 项"
          : "\(min(store.findIndex + 1, store.findMatches.count)) / \(store.findMatches.count)"
      ).appFont(.caption).foregroundStyle(.secondary)
      if store.finding { ProgressView().controlSize(.mini).accessibilityLabel("正在查找") }
      Button {
        store.moveFindMatch(-1)
      } label: {
        Image(systemName: "chevron.up")
      }.buttonStyle(.plain).disabled(!store.commandEnabled("find-previous"))
        .help("上一个匹配 \(store.shortcuts.label("find-previous"))")
        .accessibilityLabel("上一个匹配")
      Button {
        store.moveFindMatch(1)
      } label: {
        Image(systemName: "chevron.down")
      }.buttonStyle(.plain).disabled(!store.commandEnabled("find-next"))
        .help("下一个匹配 \(store.shortcuts.label("find-next"))")
        .accessibilityLabel("下一个匹配")
      Button {
        store.showingFind = false
      } label: {
        Image(systemName: "xmark")
      }.buttonStyle(.plain).help("关闭查找").accessibilityLabel("关闭查找")
    }.padding(10).onAppear { focused = true }
  }
}
