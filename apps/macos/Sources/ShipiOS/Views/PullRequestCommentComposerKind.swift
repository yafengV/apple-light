import SwiftUI

enum PullRequestCommentComposerKind: Equatable {
  case comment, edit, reply(author: String?)
  var inlineSurface: Bool { self != .comment }
  var placeholder: String {
    switch self {
    case .comment, .edit: "发表评论"
    case .reply(let author): "回复 " + (author.flatMap { $0.isEmpty ? nil : $0 } ?? "评论")
    }
  }
  var accessibilityLabel: String {
    switch self { case .comment: "PR 评论"; case .edit: "编辑 PR 评论"; case .reply: "PR 回复" }
  }
  static func avatarURL(_ login: String?) -> URL? {
    guard let login = login.map(JavaScriptText.trimmed), !login.isEmpty,
      login.rangeOfCharacter(from: JavaScriptText.whitespace) == nil else { return nil }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let escaped = login.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "https://github.com/" + escaped + ".png?size=48")
  }
}

struct PullRequestCommentComposerAvatar: View {
  let login: String
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    AsyncImage(url: PullRequestCommentComposerKind.avatarURL(login)) { phase in
      if case .success(let image) = phase { image.resizable().scaledToFill() }
      else {
        Text(String(login.prefix(1)).uppercased()).appFont(size: 12, weight: .semibold)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(appearance.resolvedColors["controlBackgroundOpaque"].color.opacity(0.6))
          .overlay(Circle().strokeBorder(appearance.resolvedColors["border"].color.opacity(0.2)))
      }
    }.frame(width: 24, height: 24).clipShape(Circle()).accessibilityHidden(true)
  }
}

struct PullRequestCommentComposerButton: View {
  let label: String
  let symbol: String
  let primary: Bool
  let busy: Bool
  let enabled: Bool
  var accessibilityName: String? = nil
  let action: () -> Void
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    Button { if enabled, !busy { action() } } label: {
      Group {
        if busy { ProgressView().controlSize(.mini).scaleEffect(0.75) }
        else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
      }.frame(width: 20, height: 20)
        .foregroundStyle(primary ? appearance.resolvedColors["controlBackgroundOpaque"].color : appearance.resolvedColors["textForeground"].color)
        .background(primary ? appearance.resolvedColors["textForeground"].color : .clear, in: Circle())
        .contentShape(Circle())
    }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(accessibilityName ?? label)
  }
}
