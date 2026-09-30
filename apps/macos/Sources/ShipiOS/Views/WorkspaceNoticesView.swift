import SwiftUI

struct WorkspaceNoticesView: View {
  let store: WorkspaceStore
  @State private var interaction: NoticeInteractionState
  @FocusState private var focused: String?
  @State private var focusExitRevision = 0
  @State private var heights: [UUID: CGFloat] = [:]
  init(store: WorkspaceStore) {
    self.store = store
    _interaction = State(initialValue: NoticeInteractionState(notices: store.notices))
  }

  var body: some View {
    let items = store.notices.items
    let layout = NoticeStackLayout(heights: items.map { heights[$0.generation] ?? 42 }, expanded: interaction.expanded)
    ZStack(alignment: .top) {
      ForEach(Array(items.enumerated()), id: \.element.generation) { index, notice in
        WorkspaceNoticeCard(store: store, notice: notice, focused: $focused, interaction: interaction,
          isFirst: index == 0, isLast: index == items.count - 1)
          .background(GeometryReader { proxy in
            Color.clear.preference(key: NoticeHeightKey.self, value: [notice.generation: proxy.size.height])
          })
          .frame(height: layout.containerHeight(index), alignment: .top)
          .scaleEffect(layout.scale(index), anchor: .center)
          .offset(y: layout.offset(index))
          .zIndex(Double(items.count - index))
          .opacity(index < 3 ? 1 : 0)
          .allowsHitTesting(index < 3)
      }
    }
    .frame(maxWidth: 768)
    .frame(height: layout.visibleExtent(3), alignment: .top)
    .padding(.horizontal, 8).padding(.top, 48)
    .onPreferenceChange(NoticeHeightKey.self) { heights = $0 }
    .onChange(of: focused) { previous, current in
      if current != nil { interaction.finishCardTabMovement() }
      if previous != nil && current == nil { focusExitRevision += 1 }
    }
    .onChange(of: items.map(\.generation)) { _, generations in
      interaction.remove(Set(generations))
      if let focused, !generations.contains(where: { focused.hasPrefix($0.uuidString) }) { self.focused = nil }
    }
    .onDisappear { interaction.stop() }
    .accessibilityElement(children: .contain).accessibilityLabel("通知")
    .background(NoticeAnnouncementSource(packets: items.map(NoticeAnnouncement.init),
      interaction: interaction).frame(width: 0, height: 0))
    .background(NoticeKeyboardBridge(interaction: interaction,
      focusFirst: {
        if let first = items.first { focused = first.generation.uuidString + "-row" }
      }, focusedCard: { focused },
      firstCard: { items.first.map { $0.generation.uuidString + "-row" } },
      lastCard: {
        items.last.map { $0.generation.uuidString + ($0.level == .pending ? "-row" : "-close") }
      }, focusExitRevision: focusExitRevision).frame(width: 0, height: 0))
    .task {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        interaction.tick()
      }
    }
  }
}

private struct NoticeHeightKey: PreferenceKey {
  static var defaultValue: [UUID: CGFloat] = [:]
  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
