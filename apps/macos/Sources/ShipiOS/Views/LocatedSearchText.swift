import SwiftUI

struct ConversationOccurrenceAnchors: PreferenceKey {
  static let defaultValue: Set<ConversationMatch.ID> = []
  static func reduce(
    value: inout Set<ConversationMatch.ID>, nextValue: () -> Set<ConversationMatch.ID>
  ) {
    value.formUnion(nextValue())
  }
}

/// Retain native Text semantics and reveal matches using actual laid-out glyphs.
@available(macOS 15, *)
struct LocatedSearchText: View {
  let text: AttributedString
  var match: ConversationMatch?
  @Environment(\.messageLinkActions) private var linkActions
  @State private var measurement: MatchMeasurement?
  @State private var layoutSize = CGSize.zero

  var body: some View {
    markedText.textRenderer(
      MatchRenderer(text: text, target: match?.id, size: layoutSize) { measured in
        if measurement != measured { measurement = measured }
      }
    )
    .background(alignment: .topLeading) {
      if let match, let measurement, measurement.text == text,
        measurement.id == match.id, let rect = measurement.rect {
        Color.clear
          .frame(width: max(1, rect.width), height: max(1, rect.height))
          .id(match.id)
          .padding(.leading, max(0, rect.minX))
          .padding(.top, max(0, rect.minY))
          .allowsHitTesting(false).accessibilityHidden(true)
          .preference(key: ConversationOccurrenceAnchors.self, value: [match.id])
      }
    }
    .overlay {
      GeometryReader { geometry in
        if let linkActions {
          MessageLinkPointerTarget(regions: measurement?.text == text && measurement?.size == geometry.size
            ? measurement?.links ?? [] : [], actions: linkActions)
        }
        Color.clear.allowsHitTesting(false)
          .onAppear { layoutSize = geometry.size }
          .onChange(of: geometry.size) { _, size in layoutSize = size }
      }
    }
    .modifier(MessageLinkAccessibility(text: text, actions: linkActions))
  }

  private var markedText: Text {
    let plain = String(text.characters)
    var selected: Range<AttributedString.Index>?
    if let match, let range = Range(match.range, in: plain),
      let start = AttributedString.Index(range.lowerBound, within: text),
      let end = AttributedString.Index(range.upperBound, within: text) { selected = start..<end }
    var boundaries = text.runs.flatMap { [$0.range.lowerBound, $0.range.upperBound] }
    if let selected { boundaries += [selected.lowerBound, selected.upperBound] }
    let ordered = boundaries.sorted().reduce(into: [AttributedString.Index]()) {
      if $0.last != $1 { $0.append($1) }
    }
    var result = Text("")
    for (start, end) in zip(ordered, ordered.dropFirst()) {
      let slice = AttributedString(text[start..<end])
      var part = Text(slice)
      if let url = slice.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        part = part.customAttribute(MessageLinkAttribute(url: url))
      }
      if let match, selected?.contains(start) == true {
        part = part.customAttribute(MatchAttribute(id: match.id))
      }
      result = Text("\(result)\(part)")
    }
    return result
  }
}

@available(macOS 15, *)
private struct MatchAttribute: TextAttribute {
  let id: ConversationMatch.ID
}
@available(macOS 15, *)
private struct MessageLinkAttribute: TextAttribute { let url: URL }
private struct MatchMeasurement: Equatable {
  let text: AttributedString
  let id: ConversationMatch.ID?
  let size: CGSize
  let rect: CGRect?
  let links: [MessageLinkRegion]
}
@available(macOS 15, *)
private struct MatchRenderer: TextRenderer {
  let text: AttributedString
  let target: ConversationMatch.ID?
  let size: CGSize
  var receive: (MatchMeasurement) -> Void

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    var first: CGRect?
    var links: [MessageLinkRegion] = []
    for line in layout {
      for run in line {
        if first == nil, let target, run[MatchAttribute.self]?.id == target {
          first = run.typographicBounds.rect
        }
        if let url = run[MessageLinkAttribute.self]?.url {
          links.append(MessageLinkRegion(url: url, rect: run.typographicBounds.rect))
        }
        context.draw(run)
      }
    }
    let measured = MatchMeasurement(text: text, id: target, size: size, rect: first, links: links)
    DispatchQueue.main.async { receive(measured) }
  }
}

struct SearchHorizontalScroll<Content: View>: View {
  @Environment(\.conversationFind) private var find
  @ViewBuilder let content: Content
  var body: some View {
    ScrollViewReader { reader in
      ScrollView(.horizontal) { content }
        .onPreferenceChange(ConversationOccurrenceAnchors.self) { anchors in
          if let match = find.active, anchors.contains(match.id) {
            reader.scrollTo(match.id, anchor: .center)
          }
        }
    }
  }
}
