import SwiftUI

struct BrowserPageFindBar: View {
  @Bindable var tab: BrowserTab
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("在网页中查找", text: $tab.pageFindQuery)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit { tab.findInPage() }
        .accessibilityIdentifier("browser-page-find-field")
      if tab.pageFindMatch == false, !tab.pageFindQuery.isEmpty {
        Text("无匹配").appFont(.caption).foregroundStyle(.secondary)
      }
      Button { tab.findInPage(backwards: true) } label: {
        Image(systemName: "chevron.up")
      }.disabled(tab.pageFindQuery.isEmpty)
        .help("上一个网页匹配 ⌘⇧G").accessibilityLabel("上一个网页匹配")
      Button { tab.findInPage() } label: {
        Image(systemName: "chevron.down")
      }.disabled(tab.pageFindQuery.isEmpty)
        .help("下一个网页匹配 ⌘G").accessibilityLabel("下一个网页匹配")
      Button { tab.closePageFind() } label: {
        Image(systemName: "xmark")
      }.help("关闭网页查找").accessibilityLabel("关闭网页查找")
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(Color.primary.opacity(0.035))
    .onChange(of: tab.pageFindQuery) { _, _ in tab.findInPage() }
    .onChange(of: tab.pageFindFocusRequest) { _, _ in focused = true }
    .onAppear { focused = true }
    .onExitCommand { tab.closePageFind() }
  }
}
