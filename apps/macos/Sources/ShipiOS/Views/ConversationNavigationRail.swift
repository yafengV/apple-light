import SwiftUI

struct ConversationRailPositions: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

struct ConversationRailPosition: ViewModifier {
  let id: String
  let space: String?
  func body(content: Content) -> some View {
    if let space {
      content.background(GeometryReader { proxy in
        Color.clear.preference(key: ConversationRailPositions.self,
          value: [id: proxy.frame(in: .named(space)).minY])
      })
    } else { content }
  }
}

extension View {
  func conversationRailPosition(_ id: String, in space: String?) -> some View {
    modifier(ConversationRailPosition(id: id, space: space))
  }
}

enum ConversationRailSelection {
  static func current(positions: [String: CGFloat], orderedIDs: [String]) -> String? {
    let visible = orderedIDs.compactMap { id in positions[id].map { (id, $0) } }
    return visible.last(where: { $0.1 <= 100 })?.0 ?? visible.first?.0
  }

  static func scrubbedID(y: CGFloat, orderedIDs: [String]) -> String? {
    guard !orderedIDs.isEmpty else { return nil }
    let index = min(orderedIDs.count - 1, max(0, Int(y / 10)))
    return orderedIDs[index]
  }
}

struct ConversationNavigationRail: View {
  let items: [ConversationRailItem]
  let currentID: String?
  let onSelect: (String) -> Void
  let onBookmark: (String, Bool) -> Void
  @State private var previewID: String?
  @State private var previewHovered = false
  @State private var scrubID: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          let highlighted = item.id == (scrubID ?? currentID)
          Button {
            onSelect(item.id)
            previewID = item.id
          } label: {
            marker(item: item, index: index, highlighted: highlighted)
              .frame(width: 36, height: 10, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("跳转到第 \(index + 1) 条用户消息\(item.bookmarked ? "，已加书签" : "")")
          .accessibilityAddTraits(item.id == currentID ? [.isSelected] : [])
          .onHover { inside in
            if inside && scrubID == nil { previewID = item.id }
            else if !inside {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if previewID == item.id && !previewHovered { previewID = nil }
              }
            }
          }
          .popover(isPresented: Binding(
            get: { previewID == item.id && scrubID == nil },
            set: { if !$0 && previewID == item.id { previewID = nil } }),
            arrowEdge: .trailing) {
            preview(item).onHover { inside in
              previewHovered = inside
              if !inside && previewID == item.id { previewID = nil }
            }
          }
        }
      }
      .coordinateSpace(name: "conversation-rail-markers")
      .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("conversation-rail-markers"))
        .onChanged { value in
          scrubID = ConversationRailSelection.scrubbedID(y: value.location.y, orderedIDs: items.map(\.id))
        }
        .onEnded { value in
          if let id = ConversationRailSelection.scrubbedID(y: value.location.y, orderedIDs: items.map(\.id)) {
            onSelect(id)
          }
          scrubID = nil
          previewID = nil
        })
    }
    .scrollIndicators(.hidden)
    .frame(width: 36)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("用户消息")
  }

  private func marker(item: ConversationRailItem, index: Int, highlighted: Bool) -> some View {
    let focus = scrubID ?? previewID
    let focusIndex = items.firstIndex(where: { $0.id == focus })
    let distance = focusIndex.map { abs($0 - index) } ?? 4
    let width: CGFloat = distance == 0 ? 26 : distance == 1 ? 20 : distance == 2 ? 16 : 12
    return HStack(spacing: 2) {
      RoundedRectangle(cornerRadius: 1).fill(highlighted || distance == 0 ? .primary : .secondary)
        .frame(width: width, height: 2)
      if item.bookmarked { Circle().fill(.primary).frame(width: 3, height: 3) }
    }
    .opacity(highlighted || distance == 0 || item.bookmarked ? 1 : 0.5)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: width)
  }

  private func preview(_ item: ConversationRailItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(item.title).appFont(.caption, weight: .medium).lineLimit(1)
        Spacer(minLength: 8)
        Button {
          onBookmark(item.id, !item.bookmarked)
        } label: {
          Image(systemName: item.bookmarked ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.plain)
        .help(item.bookmarked ? "移除书签" : "为此轮加书签")
        .accessibilityLabel(item.bookmarked ? "移除书签" : "为此轮加书签")
      }
      Text(item.preview).appFont(.caption).foregroundStyle(.secondary)
        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
      Text(item.date, style: .date).appFont(size: 11).foregroundStyle(.tertiary)
    }
    .padding(12).frame(width: 270)
  }
}

struct ConversationRailOverlay: View {
  let items: [ConversationRailItem]
  let currentID: String?
  let onSelect: (String) -> Void
  let onBookmark: (String, Bool) -> Void

  var body: some View {
    GeometryReader { proxy in
      ConversationNavigationRail(items: items, currentID: currentID,
        onSelect: onSelect, onBookmark: onBookmark)
        .frame(height: min(CGFloat(items.count) * 10, proxy.size.height * 0.7, 640))
        .position(x: 34, y: proxy.size.height / 2)
    }
    .frame(width: 56)
  }
}
