import SwiftUI

struct WorkspaceNoticesView: View {
  let store: WorkspaceStore
  @State private var hovered = false
  @FocusState private var focused: String?
  @State private var heights: [UUID: CGFloat] = [:]
  private var expanded: Bool { hovered || focused != nil }

  var body: some View {
    let items = store.notices.items
    let layout = NoticeStackLayout(heights: items.map { heights[$0.generation] ?? 42 }, expanded: expanded)
    ZStack(alignment: .top) {
      ForEach(Array(items.enumerated()), id: \.element.generation) { index, notice in
        WorkspaceNoticeCard(store: store, notice: notice, focused: $focused)
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
    .onHover { hovered = $0; store.notices.paused = expanded }
    .onChange(of: focused) { _, _ in store.notices.paused = expanded }
    .onChange(of: items.map(\.generation)) { _, generations in
      if let focused, !generations.contains(where: { focused.hasPrefix($0.uuidString) }) { self.focused = nil }
    }
    .onDisappear { store.notices.paused = false }
    .accessibilityElement(children: .contain).accessibilityLabel("通知")
    .background(NoticeAnnouncementSource(packets: items.map(NoticeAnnouncement.init)).frame(width: 0, height: 0))
    .task {
      let clock = ContinuousClock()
      var previous = clock.now
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        let now = clock.now
        let duration = previous.duration(to: now).components
        store.notices.advance(by: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        previous = now
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
