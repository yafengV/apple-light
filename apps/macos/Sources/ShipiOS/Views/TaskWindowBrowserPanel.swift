import SwiftUI

struct TaskWindowBrowserPanel: View {
  @Bindable var store: WorkspaceStore
  @Bindable var browser: TaskWindowBrowser
  let context: BrowserPanelContext

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("浏览器", systemImage: "globe").appFont(.caption, weight: .medium)
        Spacer()
        Button { browser.fullWidth.toggle() } label: {
          Image(systemName: browser.fullWidth ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right")
        }.buttonStyle(.plain).accessibilityLabel(browser.fullWidth ? "分栏显示浏览器" : "全宽显示浏览器")
        Button { browser.visible = false; context.focusComposer() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("隐藏任务浏览器")
      }.padding(10)
      Divider()
      BrowserPanel(store: store, session: browser.session, context: context)
    }
  }
}
