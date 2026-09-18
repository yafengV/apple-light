import SwiftUI

struct WorkspaceNoticesView: View {
  let store: WorkspaceStore
  @State private var hovered = false
  @FocusState private var focused: String?
  @State private var heights: [String: CGFloat] = [:]
  private var expanded: Bool { hovered || focused != nil }

  var body: some View {
    let items = store.notices.visible
    ZStack(alignment: .top) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, notice in
        card(notice)
          .background(GeometryReader { proxy in
            Color.clear.preference(key: NoticeHeightKey.self, value: [notice.id: proxy.size.height])
          })
          .scaleEffect(expanded ? 1 : 1 - CGFloat(index) * 0.05, anchor: .top)
          .offset(y: offset(index, items: items))
          .zIndex(Double(items.count - index))
          .allowsHitTesting(index == 0 || expanded)
          .accessibilityHidden(index > 0 && !expanded)
      }
    }
    .frame(maxWidth: 768)
    .frame(height: stackHeight(items), alignment: .top)
    .padding(.horizontal, 8).padding(.top, 48)
    .onPreferenceChange(NoticeHeightKey.self) { heights = $0 }
    .onHover { hovered = $0; store.notices.paused = expanded }
    .onChange(of: focused) { _, _ in store.notices.paused = expanded }
    .onDisappear { store.notices.paused = false }
    .accessibilityElement(children: .contain).accessibilityLabel("通知")
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

  private func offset(_ index: Int, items: [WorkspaceNotice]) -> CGFloat {
    expanded ? items.prefix(index).reduce(0) { $0 + (heights[$1.id] ?? 48) + 8 } : CGFloat(index) * 14
  }
  private func stackHeight(_ items: [WorkspaceNotice]) -> CGFloat {
    guard !items.isEmpty else { return 0 }
    return items.enumerated().map { offset($0.offset, items: items) + (heights[$0.element.id] ?? 48) }.max() ?? 0
  }
  private func card(_ notice: WorkspaceNotice) -> some View {
    HStack(spacing: 12) {
      if notice.level == .pending { ProgressView().controlSize(.small) }
      else {
        Image(systemName: notice.level == .error ? "exclamationmark.circle" : "checkmark.circle")
          .foregroundStyle(notice.level == .error ? Color.red : Color.primary)
      }
      Text(notice.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
      if notice.taskID != nil {
        Button("查看") { Task { await store.openNoticeTask(notice) } }
          .buttonStyle(.borderedProminent).controlSize(.small)
          .focused($focused, equals: notice.id + "-view")
          .disabled(store.hasSettingsConfirmation || store.presentedOverlay != nil)
      }
      if notice.level != .pending {
        Button { store.notices.dismiss(notice.id) } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("关闭通知")
          .focused($focused, equals: notice.id + "-close")
      }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
      if value.translation.width > 60 && abs(value.translation.height) < value.translation.width {
        store.notices.dismiss(notice.id)
      }
    })
  }
}

private struct NoticeHeightKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
