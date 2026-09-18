import SwiftUI

enum MessageLinkAction: CaseIterable {
  case openInApp, openExternal, copy, saveAs
  var title: String {
    switch self {
    case .openInApp: "在应用内浏览器打开"
    case .openExternal: "在外部浏览器打开"
    case .copy: "复制链接"
    case .saveAs: "链接另存为…"
    }
  }
}

struct MessageLinkActions {
  var activate: (URL, WebLinkClick) -> Void
  var perform: (URL, MessageLinkAction) -> Void
}

private struct MessageLinkActionsKey: EnvironmentKey {
  static let defaultValue: MessageLinkActions? = nil
}

extension EnvironmentValues {
  var messageLinkActions: MessageLinkActions? {
    get { self[MessageLinkActionsKey.self] }
    set { self[MessageLinkActionsKey.self] = newValue }
  }
}

struct MessageLinkRegion: Equatable {
  let url: URL
  let rect: CGRect
}

struct MessageAccessibleLink: Identifiable, Equatable {
  let id: Int
  let url: URL
  var label: String

  static func links(in text: AttributedString) -> [Self] {
    var links: [Self] = []
    var previousURL: URL?
    for run in text.runs {
      guard let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
        previousURL = nil
        continue
      }
      let label = String(text[run.range].characters)
      if previousURL == url, let last = links.indices.last { links[last].label += label }
      else { links.append(Self(id: links.count, url: url, label: label)) }
      previousURL = url
    }
    return links
  }
  func title(for action: MessageLinkAction) -> String {
    "\(action.title)：\(label)（\(url.absoluteString)）"
  }
}

struct MessageLinkAccessibility: ViewModifier {
  let text: AttributedString
  let actions: MessageLinkActions?
  func body(content: Content) -> some View {
    if let actions {
      content.accessibilityActions {
        ForEach(MessageAccessibleLink.links(in: text)) { link in
          ForEach(MessageLinkAction.allCases, id: \.self) { action in
            Button(link.title(for: action)) { actions.perform(link.url, action) }
          }
        }
      }
    } else { content }
  }
}
