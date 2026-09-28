import SwiftUI

/// Activity replaces the task sidebar, keeping the conversation and its panels mounted.
struct ActivityView: View {
  @Bindable var store: WorkspaceStore
  @State private var focusedID: String?
  @FocusState private var listFocused: Bool

  private var sections: [ActivitySection] { store.activitySections() }
  private var items: [ActivityTaskEntry] { sections.flatMap(\.items) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Button { store.closeActivity() } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).help("关闭活动视图 \(store.shortcuts.label("activity"))")
          .accessibilityLabel("关闭活动视图")
        Text("活动").appFont(size: 17, weight: .semibold)
        Spacer(minLength: 0)
        if store.activityPriorityEntries.contains(where: { !$0.needsAttention }) {
          Button { store.clearReadActivity() } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).help("清除已读任务").accessibilityLabel("清除已读任务")
        }
        options
      }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
      if let error = store.activityError {
        HStack(alignment: .top) {
          Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
          Button { store.activityError = nil } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("关闭活动错误")
        }.padding(.horizontal, 14).padding(.bottom, 8)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
              Text(section.title).appFont(.caption, weight: .medium).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
              if section.id == .priority && section.items.isEmpty {
                Text("没有需要关注的任务").appFont(.callout).foregroundStyle(.tertiary)
                  .padding(.horizontal, 10).padding(.vertical, 14)
              }
              ForEach(section.items) { item in row(item).id(item.id) }
            }
            if sections.isEmpty {
              Text("暂无近期活动").appFont(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 24)
            }
          }.padding(.horizontal, 8).padding(.bottom, 12)
        }
        .focusable().focused($listFocused).focusEffectDisabled()
        .onKeyPress(.upArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.downArrow) { moveFocus(1); return .handled }
        .onKeyPress(.return) {
          guard let id = focusedID else { return .ignored }
          open(id)
          return .handled
        }
        .onChange(of: focusedID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .onChange(of: items.map(\.id)) { _, ids in
          if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        }
        .onChange(of: store.selectedTask?.id) { _, id in
          if let id, items.contains(where: { $0.id == id }) { focusedID = id }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityIdentifier("activity-sidebar")
      .onAppear { listFocused = true }
      .onChange(of: store.archiveConfirmation()?.id) { previous, current in
        if previous != nil, current == nil, store.destination != .settings,
          store.presentedOverlay == nil, !store.hasSettingsConfirmation { listFocused = true }
      }
  }

  private var options: some View {
    Menu {
      Section("显示") {
        Toggle("优先处理区域", isOn: option(\.showPriority))
        Toggle("已置顶", isOn: option(\.showPinned))
        Toggle("计划任务", isOn: option(\.showScheduled))
        if store.library.activityPreferences != ActivityPreferences() {
          Button("恢复默认值") { store.restoreActivityDefaults() }
        }
      }
      Divider()
      Button("全部标为已读") { store.markActivityRead() }
        .disabled(!store.activityPriorityEntries.contains(where: \.unread))
      Button("归档任务") { store.requestActivityArchive() }
        .disabled(store.activityArchiveEligibleIDs.isEmpty || !store.canMutateArchive)
    } label: { Image(systemName: "ellipsis") }
      .menuStyle(.borderlessButton).frame(width: 22)
      .help("活动视图选项").accessibilityLabel("活动视图选项")
  }

  private func option(_ key: WritableKeyPath<ActivityPreferences, Bool>) -> Binding<Bool> {
    Binding(get: { store.library.activityPreferences[keyPath: key] },
      set: { store.setActivityOption(key, to: $0) })
  }

  private func moveFocus(_ offset: Int) {
    let ids = items.filter { store.canSelectTask($0.task) }.map(\.id)
    guard !ids.isEmpty else { return }
    let index = focusedID.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
    focusedID = ids[min(max(index + offset, 0), ids.count - 1)]
  }

  private func open(_ id: String) {
    guard let sessionID = store.activitySession?.id else { return }
    Task {
      guard store.activitySession?.id == sessionID else { return }
      _ = await store.openActivityTask(id)
    }
  }

  private func row(_ item: ActivityTaskEntry) -> some View {
    ActivityTaskRow(store: store, item: item, opening: store.activityOpeningTaskID == item.id,
      openingAny: store.activityOpeningTaskID != nil, focused: focusedID == item.id && listFocused) {
        focusedID = item.id
        open(item.id)
      }
  }
}
