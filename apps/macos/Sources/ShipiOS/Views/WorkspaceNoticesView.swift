import SwiftUI

struct WorkspaceNoticesView: View {
  let store: WorkspaceStore
  @State private var interaction: NoticeInteractionState
  @State private var visual: NoticeVisualTimeline
  @FocusState private var focused: String?
  @State private var focusExitRevision = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  init(store: WorkspaceStore, timeline: NoticeVisualTimeline? = nil) {
    self.store = store
    _interaction = State(initialValue: NoticeInteractionState(notices: store.notices))
    _visual = State(initialValue: timeline ?? NoticeVisualTimeline(initial: store.notices.items))
  }

  var body: some View {
    let items = store.notices.items
    let displayed = visual.active
    let layout = NoticeStackLayout(heights: displayed.map { visual.heights[$0.generation] ?? 42 },
      expanded: interaction.expanded)
    let stackAnimation: Animation? = reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4)
    let actionsEnabled = !((store.hasSettingsConfirmation && store.appearanceThemeImport == nil)
      || store.presentedOverlay != nil)
    ZStack(alignment: .top) {
      ForEach(Array(displayed.enumerated()), id: \.element.generation) { index, notice in
        let entering = visual.entering.contains(notice.generation)
        WorkspaceNoticeCard(store: store, notice: notice, focused: $focused, interaction: interaction,
          isFirst: index == 0, isLast: index == displayed.count - 1,
          onSwipeDismiss: { visual.markSwiped($0) })
          .background(GeometryReader { proxy in
            Color.clear.preference(key: NoticeHeightKey.self, value: [notice.generation: proxy.size.height])
          })
          .frame(height: layout.containerHeight(index), alignment: .top)
          .scaleEffect(layout.scale(index), anchor: .center)
          .offset(y: layout.offset(index) - (entering ? visual.heights[notice.generation] ?? 42 : 0))
          .zIndex(Double(displayed.count - index))
          .opacity(index < 3 && !entering ? 1 : 0)
          .allowsHitTesting(index < 3)
          .transition(.identity)
      }
      ForEach(visual.exiting) { exit in
        WorkspaceNoticeCard(store: store, notice: exit.notice, focused: $focused)
          .frame(height: exit.frameHeight, alignment: .top)
          .scaleEffect(exit.scale, anchor: .center)
          .offset(y: exit.offset + (exit.outward ? exit.exitOffset : 0))
          .animation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1,
            duration: exit.leavesUpward ? 0.4 : 0.5), value: exit.outward)
          .zIndex(Double(displayed.count + visual.exiting.count - exit.index + 1))
          .opacity(exit.index < 3 && !exit.outward ? 1 : 0)
          .animation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1,
            duration: exit.leavesUpward ? 0.4 : 0.2), value: exit.outward)
          .allowsHitTesting(false).accessibilityHidden(true)
          .transition(.identity)
      }
    }
    .animation(stackAnimation, value: interaction.expanded)
    .frame(maxWidth: 768)
    .frame(height: layout.visibleExtent(3), alignment: .top)
    .padding(.horizontal, 8).padding(.top, 48)
    .allowsHitTesting(!displayed.isEmpty)
    .onPreferenceChange(NoticeHeightKey.self) { visual.recordHeights($0) }
    .onChange(of: focused) { previous, current in
      if current != nil { interaction.finishCardTabMovement() }
      if previous != nil && current == nil { focusExitRevision += 1 }
    }
    .onChange(of: items.map(\.generation)) { _, generations in
      synchronize(items)
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
      lastCard: { NoticeTabOrder.tokens(for: displayed, actionsEnabled: actionsEnabled).last },
      focusOrder: { NoticeTabOrder.tokens(for: displayed, actionsEnabled: actionsEnabled) },
      focusCard: { focused = $0 },
      focusExitRevision: focusExitRevision).frame(width: 0, height: 0))
    .task(id: items.isEmpty) {
      guard !items.isEmpty else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        interaction.tick()
      }
    }
  }

  private func synchronize(_ items: [WorkspaceNotice]) {
    let now = ProcessInfo.processInfo.systemUptime
    var changed = false
    withAnimation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4)) {
      changed = visual.reconcile(items, expanded: interaction.expanded, at: now)
    }
    guard changed else { return }
    let revision = visual.revision
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(16))
      withAnimation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4)) {
        visual.settleEntry(revision: revision)
      }
      visual.beginExit(revision: revision)
      try? await Task.sleep(for: .milliseconds(184))
      visual.removeFinished(at: ProcessInfo.processInfo.systemUptime)
    }
  }
}

private struct NoticeHeightKey: PreferenceKey {
  static var defaultValue: [UUID: CGFloat] = [:]
  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
