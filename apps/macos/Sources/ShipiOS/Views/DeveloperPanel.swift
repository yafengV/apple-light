import SwiftUI

struct DeveloperPanel: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        ViewThatFits(in: .horizontal) {
          tabs.labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
          tabs.labelStyle(.iconOnly).fixedSize(horizontal: true, vertical: false)
        }
        Spacer(minLength: 0)
        Button {
          store.showingInspector = false
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).help("隐藏右侧面板").accessibilityLabel("隐藏右侧面板")
      }.appFont(.caption).padding(12)
        .contextMenu { Button("恢复默认面板宽度") { store.resetInspectorSize() } }
      Divider()
      Group {
        switch store.pane {
        case "files": FileWorkspaceView(store: store, workspace: store.workspace)
        case "review", "browser": ProgressView().controlSize(.small)
        default: RunInspectorView(store: store)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private var tabs: some View {
    HStack(spacing: 14) {
      panelButton("文件", "files", "doc")
      panelButton("审查", "review", "square.stack.3d.up")
      panelButton("浏览器", "browser", "globe")
      panelButton("执行", "execution", "list.bullet.rectangle")
    }
  }
  private func panelButton(_ title: String, _ value: String, _ icon: String) -> some View {
    Button {
      store.showPane(value)
    } label: {
      Label(title, systemImage: icon).foregroundStyle(
        store.pane == value ? Color.primary : .secondary)
    }.buttonStyle(.plain).help(title).accessibilityLabel(title)
      .accessibilityAddTraits(store.pane == value ? .isSelected : [])
  }
}
