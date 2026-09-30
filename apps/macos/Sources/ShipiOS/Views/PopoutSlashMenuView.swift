import SwiftUI

struct PopoutSlashMenuView: View {
  @Bindable var store: WorkspaceStore
  @Binding var selection: PopoutSlashSelection
  let maximumHeight: CGFloat
  let accept: (PopoutSlashItem) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(selection.stage == .recent ? "最近聊天" : "命令")
          .appFont(size: 11, weight: .semibold).foregroundStyle(.secondary)
        Spacer()
      }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(selection.items, id: \.self) { item in
              Button { choose(item) } label: {
                HStack(spacing: 9) {
                  Image(systemName: icon(for: item))
                    .frame(width: 17).foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: item)).lineLimit(1)
                    if let detail = detail(for: item) {
                      Text(detail).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
                    }
                  }
                  Spacer(minLength: 4)
                  if case .resume = item {
                    Image(systemName: "chevron.right").appFont(size: 10)
                      .foregroundStyle(.secondary)
                  } else if case .task(let id) = item {
                    if store.activeRun(taskID: id) != nil {
                      Image(systemName: "circle.dotted").help("运行中")
                    } else if store.library.unreadTasks.contains(id) {
                      Circle().fill(store.appearance.accentColor)
                        .frame(width: 6, height: 6).help("未读")
                    }
                  }
                }
                .appFont(.caption).padding(.horizontal, 10).frame(height: 39)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selection.selected == item ? Color.primary.opacity(0.09) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain).disabled(item == .empty)
              .onHover { if $0 { selection.highlight(item) } }
              .accessibilityAddTraits(selection.selected == item ? .isSelected : [])
              .id(item)
            }
          }.padding(.horizontal, 6).padding(.bottom, 4)
        }.frame(maxHeight: max(40, maximumHeight - 55))
          .onChange(of: selection.selected) { _, item in
            if let item { reader.scrollTo(item, anchor: .center) }
          }
      }
      Divider()
      Text(selection.stage == .recent
        ? "↑↓ 选择 · ↵ 打开 · esc 返回"
        : "↑↓ 选择 · ↵ / Tab 确认 · esc 关闭")
        .appFont(size: 10).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
    .frame(maxWidth: .infinity)
    .frame(height: min(maximumHeight, CGFloat(selection.items.count) * 41 + 60))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    .accessibilityLabel("弹出窗口斜杠命令")
    .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape], phases: .down) { press in
      guard press.modifiers.isEmpty else { return .ignored }
      let key: PopoutSlashSelection.Key
      switch press.key {
      case .upArrow: key = .previous
      case .downArrow: key = .next
      case .escape: key = .dismiss
      default: key = .accept
      }
      switch selection.handle(key) {
      case .ignored: return .ignored
      case .handled: return .handled
      case .accept(let item): accept(item); return .handled
      }
    }
  }

  private func choose(_ item: PopoutSlashItem) {
    guard item != .empty else { return }
    selection.highlight(item)
    if case .accept(let result) = selection.handle(.accept) { accept(result) }
  }

  private func icon(for item: PopoutSlashItem) -> String {
    switch item {
    case .new: "plus"
    case .resume: "clock.arrow.circlepath"
    case .task: "bubble.left"
    case .empty: "clock"
    }
  }

  private func title(for item: PopoutSlashItem) -> String {
    switch item {
    case .new: "/new · 新建"
    case .resume: "/resume · 恢复"
    case .task(let id): selection.recentTasks.first { $0.id == id }?.title ?? id
    case .empty: "没有最近聊天"
    }
  }

  private func detail(for item: PopoutSlashItem) -> String? {
    switch item {
    case .new: return "返回弹出窗口首页"
    case .resume: return "继续最近聊天"
    case .task(let id):
      guard let task = selection.recentTasks.first(where: { $0.id == id }) else { return nil }
      return task.project.isEmpty ? "独立聊天" : store.library.projectTitle(task.project)
    case .empty: return nil
    }
  }
}
