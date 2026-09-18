import SwiftUI

struct TaskWindowTabStrip: View {
  @Bindable var store: WorkspaceStore
  let resources: TaskWindowResources
  @Bindable var tabs: TaskWindowTabs
  let title: String
  var placement: WorkspaceTabPlacement = .left
  let defaultReviewScope: GitReviewScope
  let openFiles: () -> Void
  let openPlugins: () -> Void
  let openAutomations: () -> Void
  @State private var showingLauncher = false

  var body: some View {
    HStack(spacing: 4) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 2) {
            if placement == .left {
              Button { tabs.activate(nil) } label: {
                Label(title, systemImage: "bubble.left.and.bubble.right")
                  .lineLimit(1).frame(maxWidth: 180)
                  .padding(.horizontal, 10).padding(.vertical, 7)
                  .background(tabs.chatVisible ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
              }
              .buttonStyle(.plain).help(title).accessibilityLabel("聊天标签：\(title)")
              .accessibilityAddTraits(tabs.chatVisible ? .isSelected : [])
              .id("chat")
              .contextMenu {
                Button("关闭其他标签页") { tabs.closeOthers(keeping: nil, in: .left) }
                  .disabled(tabs.visibleTabs(.left).isEmpty)
                Button("关闭右侧标签页") { tabs.closeRight(of: nil, in: .left) }
                  .disabled(!tabs.canCloseRight(of: nil, in: .left))
              }
            }
            ForEach(tabs.visibleTabs(placement)) { tab in
              TaskWindowTabChip(store: store, resources: resources, tabs: tabs, tab: tab).id(tab.id)
            }
          }.padding(.horizontal, 8)
        }.scrollIndicators(.hidden)
        .onChange(of: tabs.selected(placement)?.id) { _, id in
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id ?? "chat", anchor: .center) }
        }
      }
      Button { showingLauncher.toggle() } label: { Image(systemName: "plus") }
        .buttonStyle(.plain).padding(8).accessibilityLabel(placement == .bottom ? "打开底部面板标签" : "新标签页")
        .popover(isPresented: $showingLauncher, arrowEdge: .bottom) { launcher }
      if placement != .left {
        Button { tabs.hide(placement) } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).padding(.trailing, 10)
          .accessibilityLabel(placement == .bottom ? "隐藏底部面板" : "隐藏右侧面板")
      }
    }
    .frame(height: 38).appFont(.caption).background(Color.primary.opacity(0.025))
  }

  private var launcher: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if placement == .bottom {
          section("终端") {
            action("打开底部终端", icon: "terminal") { tabs.newTerminal() }
          }
        } else {
          section("推荐") {
            action("浏览器", icon: "globe") { tabs.newBrowser(in: placement) }
            if tabs.panels.workspace.root != nil {
              action("审查", icon: "square.stack.3d.up") {
                tabs.openReview(in: placement, defaultScope: defaultReviewScope)
              }
              action("打开底部终端", icon: "terminal") { tabs.newTerminal() }
            }
          }
          section("最近工作") {
            if tabs.canReopen {
              action("重新打开关闭的标签页", icon: "arrow.uturn.backward") { tabs.reopen() }
            } else { Text("暂无最近关闭的标签页").foregroundStyle(.secondary).appFont(.caption) }
          }
          section("插件和 MCP") { action("浏览插件", icon: "shippingbox", perform: openPlugins) }
          section("更多工具") {
            if tabs.panels.workspace.root != nil { action("文件", icon: "doc.text.magnifyingglass", perform: openFiles) }
            action("自动化", icon: "clock.arrow.circlepath", perform: openAutomations)
          }
        }
      }.padding(16)
    }.frame(width: 320, height: placement == .bottom ? 110 : 430)
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
      content()
    }
  }
  private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
    Button { showingLauncher = false; perform() } label: {
      Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct TaskWindowTabChip: View {
  @Bindable var store: WorkspaceStore
  let resources: TaskWindowResources
  @Bindable var tabs: TaskWindowTabs
  let tab: WorkspaceContentTab
  @State private var width: CGFloat = 0
  @State private var targeted = false
  var body: some View {
    HStack(spacing: 5) {
      Button { tabs.activate(tab.id) } label: {
        Label(tabs.title(tab), systemImage: tab.icon).lineLimit(1).frame(maxWidth: 150)
      }.buttonStyle(.plain).help(tabs.title(tab)).accessibilityLabel("内容标签：\(tabs.title(tab))")
      Button { tabs.close(tab.id) } label: { Image(systemName: "xmark").appFont(size: 9) }
        .buttonStyle(.plain).accessibilityLabel("关闭标签：\(tabs.title(tab))")
    }
    .padding(.horizontal, 9).padding(.vertical, 7)
    .background(tabs.selected(tabs.placement(tab.id))?.id == tab.id ? Color.primary.opacity(0.09) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
    .background {
      GeometryReader { geometry in
        Color.clear.onAppear { width = geometry.size.width }
          .onChange(of: geometry.size.width) { _, value in width = value }
      }
    }
    .overlay { if targeted { RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2) } }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(tabs.selected(tabs.placement(tab.id))?.id == tab.id ? .isSelected : [])
    .onDrag { NSItemProvider(object: tabs.dragToken(tab.id) as NSString) }
    .dropDestination(for: String.self) { values, location in
      guard let source = values.compactMap(tabs.draggedTab).first else { return false }
      return tabs.reorder(source, relativeTo: tab.id, after: location.x > width / 2)
    } isTargeted: { targeted = $0 }
    .contextMenu {
      Button(store.isWorkspaceTabPinned(tab.id, windowID: resources.id) ? "从侧栏取消固定" : "固定到侧栏") {
        if store.isWorkspaceTabPinned(tab.id, windowID: resources.id) {
          store.unpinWorkspaceTab(tab.id, windowID: resources.id)
        } else { resources.pin(tab.id, taskID: tabs.taskID) }
      }
      Divider()
      ForEach([WorkspaceTabPlacement.left, .right, .bottom], id: \.self) { place in
        if tabs.placement(tab.id) != place, tabs.canMove(tab.id, to: place) {
          Button("移到\(place.label)") { tabs.move(tab.id, to: place) }
        }
      }
      Divider()
      Button("关闭") { tabs.close(tab.id) }
      Button("关闭其他标签页") { tabs.closeOthers(keeping: tab.id, in: tabs.placement(tab.id)) }
        .disabled(tabs.visibleTabs(tabs.placement(tab.id)).count <= 1)
      Button("关闭右侧标签页") { tabs.closeRight(of: tab.id, in: tabs.placement(tab.id)) }
        .disabled(!tabs.canCloseRight(of: tab.id, in: tabs.placement(tab.id)))
    }
  }
}

extension View {
  func taskWindowDropDestination(tabs: TaskWindowTabs, placement: WorkspaceTabPlacement) -> some View {
    dropDestination(for: String.self) { values, _ in
      guard let id = values.compactMap(tabs.draggedTab).first, tabs.canMove(id, to: placement) else { return false }
      tabs.move(id, to: placement); return true
    }
  }
}
