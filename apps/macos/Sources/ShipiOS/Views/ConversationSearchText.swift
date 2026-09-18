import SwiftUI

struct ConversationFindContext {
  var query = ""
  var active: ConversationMatch?
}
private struct ConversationFindKey: EnvironmentKey {
  static let defaultValue = ConversationFindContext()
}
private struct ConversationRunKey: EnvironmentKey {
  static let defaultValue = ""
}
private struct ConversationResponsePartKey: EnvironmentKey {
  static let defaultValue = "response"
}
struct ConversationTextAnchors: PreferenceKey {
  static let defaultValue: Set<ConversationTextID> = []
  static func reduce(value: inout Set<ConversationTextID>, nextValue: () -> Set<ConversationTextID>)
  {
    value.formUnion(nextValue())
  }
}
extension EnvironmentValues {
  var conversationResponsePart: String {
    get { self[ConversationResponsePartKey.self] }
    set { self[ConversationResponsePartKey.self] = newValue }
  }
  var conversationRunID: String {
    get { self[ConversationRunKey.self] }
    set { self[ConversationRunKey.self] = newValue }
  }
  var conversationFind: ConversationFindContext {
    get { self[ConversationFindKey.self] }
    set { self[ConversationFindKey.self] = newValue }
  }
}

enum ConversationHighlight {
  static func apply(
    _ original: AttributedString, query: String, activeRange: NSRange?
  ) -> AttributedString {
    var text = original
    let plain = String(text.characters)
    for range in ConversationSearch.ranges(in: plain, query: query) {
      guard let stringRange = Range(range, in: plain),
        let start = AttributedString.Index(stringRange.lowerBound, within: text),
        let end = AttributedString.Index(stringRange.upperBound, within: text)
      else { continue }
      text[start..<end].backgroundColor =
        range == activeRange ? .orange.opacity(0.7) : .yellow.opacity(0.35)
      text[start..<end].foregroundColor = .black
    }
    return text
  }
}

struct ConversationSearchText: View {
  @Environment(\.conversationFind) private var find
  @Environment(\.messageLinkActions) private var linkActions
  let text: AttributedString
  let id: ConversationTextID
  var nativeFontSize: CGFloat = 14
  var nativeWeight: NSFont.Weight = .regular

  init(_ text: String, id: ConversationTextID) {
    self.text = AttributedString(text)
    self.id = id
  }
  init(_ text: AttributedString, id: ConversationTextID, nativeFontSize: CGFloat = 14,
    nativeWeight: NSFont.Weight = .regular) {
    self.text = text
    self.id = id
    self.nativeFontSize = nativeFontSize
    self.nativeWeight = nativeWeight
  }
  var body: some View {
    let active = find.active?.textID == id ? find.active : nil
    let highlighted = ConversationHighlight.apply(
      text, query: find.query, activeRange: active?.range)
    Group {
      if #available(macOS 15, *), active != nil || (linkActions != nil && text.runs.contains { $0.link != nil }) {
        LocatedSearchText(text: highlighted, match: active)
      } else if let linkActions, text.runs.contains(where: { $0.link != nil }) {
        LegacyMessageLinkText(text: highlighted, fontSize: nativeFontSize, weight: nativeWeight,
          actions: linkActions)
      } else {
        Text(highlighted)
      }
    }.id(id).preference(key: ConversationTextAnchors.self, value: [id])
  }
}
