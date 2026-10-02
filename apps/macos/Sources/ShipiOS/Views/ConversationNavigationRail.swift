import AppKit
import SwiftUI

struct ConversationRailPositions: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

struct ConversationRailViewportHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct ConversationRailPosition: ViewModifier {
  let id: String
  let space: String?
  func body(content: Content) -> some View {
    if let space {
      content.background(GeometryReader { proxy in
        Color.clear.preference(key: ConversationRailPositions.self,
          value: [id: proxy.frame(in: .named(space))])
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
  static func visibleIDs(positions: [String: CGRect], orderedIDs: [String],
    viewportHeight: CGFloat) -> Set<String> {
    guard viewportHeight > 0 else { return [] }
    let visible = orderedIDs.indices.filter { index in
      guard let bounds = positions[orderedIDs[index]] else { return false }
      return bounds.maxY > 16 && bounds.minY < viewportHeight
    }
    guard let first = visible.first, let last = visible.last else { return [] }
    return Set(orderedIDs[first...last])
  }

  static func scrubbedID(y: CGFloat, orderedIDs: [String]) -> String? {
    guard !orderedIDs.isEmpty else { return nil }
    let index = min(orderedIDs.count - 1, max(0, Int(y / 10)))
    return orderedIDs[index]
  }

  static func scrubNavigationTarget(startY: CGFloat, y: CGFloat,
    previousID: String?, orderedIDs: [String]) -> String? {
    guard let target = scrubbedID(y: y, orderedIDs: orderedIDs),
      target != previousID else { return nil }
    if previousID == nil && target == scrubbedID(y: startY, orderedIDs: orderedIDs) {
      return nil
    }
    return target
  }

  static func audioLevel(index: Int, itemCount: Int, levels: [Double]) -> Double {
    guard itemCount > 0, !levels.isEmpty, index >= 0, index < itemCount else { return 0 }
    let first = index * levels.count / itemCount
    let last = max(first, ((index + 1) * levels.count + itemCount - 1) / itemCount - 1)
    return levels[first...min(last, levels.count - 1)].max() ?? 0
  }
}

struct ConversationNavigationRail: View {
  static let minimumItems = 4
  let items: [ConversationRailItem]
  let currentIDs: Set<String>
  let onSelect: (String) -> Void
  let onBookmark: (String, Bool) -> Void
  var audioLevels: [Double] = []
  @State private var previewID: String?
  @State private var previewHovered = false
  @State private var scrubID: String?
  @State private var suppressClickAfterScrub = false
  @FocusState private var focusedID: String?
  @FocusState private var bookmarkFocusedID: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          let highlighted = item.id == scrubID || currentIDs.contains(item.id)
          Button {
            if suppressClickAfterScrub {
              suppressClickAfterScrub = false
              return
            }
            navigate(to: item.id, animated: true)
            previewID = item.id
          } label: {
            marker(item: item, index: index, highlighted: highlighted)
              .frame(width: 36, height: 10, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focused($focusedID, equals: item.id)
          .accessibilityLabel("跳转到第 \(index + 1) 条用户消息\(item.bookmarked ? "，已加书签" : "")")
          .accessibilityAddTraits(currentIDs.contains(item.id) ? [.isSelected] : [])
          .onHover { inside in
            if inside && scrubID == nil { previewID = item.id }
            else if !inside {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if previewID == item.id && !previewHovered && focusedID != item.id
                  && bookmarkFocusedID != item.id {
                  previewID = nil
                }
              }
            }
          }
          .popover(isPresented: Binding(
            get: { (scrubID ?? previewID) == item.id },
            set: { if !$0 && previewID == item.id { previewID = nil } }),
            arrowEdge: .trailing) {
            preview(item).onHover { inside in
              previewHovered = inside
              if !inside && previewID == item.id && focusedID != item.id
                && bookmarkFocusedID != item.id {
                previewID = nil
              }
            }
          }
        }
      }
      .coordinateSpace(name: "conversation-rail-markers")
      .simultaneousGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("conversation-rail-markers"))
        .onChanged { value in
          let orderedIDs = items.map(\.id)
          let next = ConversationRailSelection.scrubbedID(y: value.location.y,
            orderedIDs: orderedIDs)
          let target = ConversationRailSelection.scrubNavigationTarget(
            startY: value.startLocation.y, y: value.location.y,
            previousID: scrubID, orderedIDs: orderedIDs)
          scrubID = next
          if let target {
            suppressClickAfterScrub = true
            navigate(to: target, animated: false)
          }
        }
        .onEnded { _ in
          scrubID = nil
          previewID = nil
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            suppressClickAfterScrub = false
          }
        })
    }
    .onChange(of: focusedID) { _, focused in
      if let focused { previewID = focused }
      else { dismissPreviewAfterFocusChange() }
    }
    .onChange(of: bookmarkFocusedID) { _, focused in
      if let focused { previewID = focused }
      else { dismissPreviewAfterFocusChange() }
    }
    .scrollIndicators(.hidden)
    .frame(width: 36)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("用户消息")
  }

  private func navigate(to id: String, animated: Bool) {
    if animated && !reduceMotion {
      withAnimation(.easeInOut(duration: 0.28)) { onSelect(id) }
    } else { onSelect(id) }
  }

  private func dismissPreviewAfterFocusChange() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      if focusedID == nil && bookmarkFocusedID == nil && !previewHovered
        && scrubID == nil { previewID = nil }
    }
  }

  private func marker(item: ConversationRailItem, index: Int, highlighted: Bool) -> some View {
    let focus = scrubID ?? previewID
    let focusIndex = items.firstIndex(where: { $0.id == focus })
    let distance = focusIndex.map { abs($0 - index) } ?? 4
    let audio = ConversationRailSelection.audioLevel(index: index,
      itemCount: items.count, levels: audioLevels)
    let progress: Double = distance == 0 ? 1 : distance == 1 ? 0.7
      : distance == 2 ? 0.4 : distance == 3 ? 0.2 : audio
    let width = CGFloat(6 + 20 * progress)
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
        .focused($bookmarkFocusedID, equals: item.id)
        .help(item.bookmarked ? "移除书签" : "为此轮加书签")
        .accessibilityLabel(item.bookmarked ? "移除书签" : "为此轮加书签")
      }
      switch item.previewState {
      case .loading:
        VStack(alignment: .leading, spacing: 6) {
          ForEach([1.0, 0.9, 0.75], id: \.self) { fraction in
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.1))
              .frame(maxWidth: .infinity, alignment: .leading).frame(height: 11)
              .scaleEffect(x: fraction, anchor: .leading)
          }
        }
        .accessibilityLabel("正在加载回复预览")
      case .unavailable:
        Text("预览不可用").appFont(.caption).foregroundStyle(.secondary)
      case .ready:
        if !item.preview.isEmpty {
          ConversationRailMarkdownPreview(source: item.preview)
        }
      }
      if item.previewState != .loading &&
        (!item.outputs.isEmpty || item.additionalOutputCount > 0) {
        HStack(spacing: 12) {
          ForEach(item.outputs.prefix(2)) { output in
            Label(output.label, systemImage: output.icon)
              .appFont(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
              .frame(maxWidth: 140, alignment: .leading)
              .accessibilityLabel("产物：\(output.label)")
          }
          let remaining = max(0, item.outputs.count - 2) + item.additionalOutputCount
          if remaining > 0 {
            Text("+\(remaining)").appFont(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("另有 \(remaining) 项产物")
          }
        }
      }
    }
    .padding(12).frame(width: 320)
  }
}

struct ConversationRailOverlay: View {
  let items: [ConversationRailItem]
  let currentIDs: Set<String>
  let onSelect: (String) -> Void
  let onBookmark: (String, Bool) -> Void
  let visualizer: SystemAudioVisualizer
  let audioEnabled: Bool
  let onAudioError: (String) -> Void
  @State private var audioLease: UUID?

  var body: some View {
    GeometryReader { proxy in
      if items.count >= ConversationNavigationRail.minimumItems {
        ConversationNavigationRail(items: items, currentIDs: currentIDs,
          onSelect: onSelect, onBookmark: onBookmark,
          audioLevels: audioEnabled ? visualizer.levels : [])
          .frame(height: min(CGFloat(items.count) * 10, proxy.size.height * 0.7, 640))
          .position(x: 34, y: proxy.size.height / 2)
      }
    }
    .frame(width: 56)
    .onAppear { reconcileAudio() }
    .onChange(of: audioEnabled) { _, _ in reconcileAudio() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      visualizer.stop()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if audioEnabled { visualizer.resumeIfNeeded() }
    }
    .onChange(of: visualizer.error) { _, error in
      if let error { onAudioError(error) }
    }
    .onDisappear {
      if let audioLease { visualizer.detach(audioLease); self.audioLease = nil }
    }
  }

  private func reconcileAudio() {
    if audioEnabled && items.count >= ConversationNavigationRail.minimumItems {
      if audioLease == nil { audioLease = visualizer.attach() }
    } else if let audioLease {
      visualizer.detach(audioLease)
      self.audioLease = nil
    }
  }
}
