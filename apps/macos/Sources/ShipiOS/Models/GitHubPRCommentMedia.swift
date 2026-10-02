import Foundation
import Markdown

struct GitHubPRCommentMedia: Equatable {
  enum Kind: Equatable { case image, video }
  let url: URL
  let kind: Kind
  let alt: String

  static func allowedURL(_ source: String) -> URL? {
    guard let url = URL(string: source), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      parts.port == nil, parts.fragment == nil, let host = parts.host?.lowercased() else { return nil }
    let path = parts.path
    switch host {
    case "github.com":
      let components = path.split(separator: "/")
      guard components.count == 3, components[0] == "user-attachments",
        components[1] == "assets", !components[2].isEmpty else { return nil }
    case "user-images.githubusercontent.com", "private-user-images.githubusercontent.com":
      guard path.count > 1 else { return nil }
    default: return nil
    }
    return url
  }

  static func videoURL(_ source: String) -> URL? {
    guard let url = allowedURL(source) else { return nil }
    let path = url.path.lowercased()
    guard path.hasPrefix("/user-attachments/assets/") ||
      [".mov", ".mp4", ".webm"].contains(where: path.hasSuffix) else { return nil }
    return url
  }
}

enum GitHubPRCommentSegment: Equatable {
  case markdown(String)
  case media(GitHubPRCommentMedia)

  static func parse(_ source: String) -> [Self] {
    var result: [Self] = []
    var pending: [String] = []
    func flush() {
      let text = pending.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { result.append(.markdown(text)) }
      pending.removeAll()
    }
    func append(_ media: GitHubPRCommentMedia) {
      flush()
      result.append(.media(media))
    }
    for block in Document(parsing: source).children {
      if let paragraph = block as? Paragraph {
        let paragraphSource = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = GitHubPRCommentMedia.videoURL(paragraphSource) {
          append(.init(url: url, kind: .video, alt: paragraphSource))
          continue
        }
        var inline: [String] = []
        var foundMedia = false
        func flushInline() {
          let text = inline.joined().trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { pending.append(text); flush() }
          inline.removeAll()
        }
        for child in paragraph.children {
          if let image = child as? Markdown.Image, let destination = image.source,
            let url = GitHubPRCommentMedia.allowedURL(destination) {
            flushInline()
            append(.init(url: url, kind: .image, alt: image.plainText))
            foundMedia = true
          } else if paragraph.childCount == 1, let link = child as? Markdown.Link,
            let destination = link.destination,
            let url = GitHubPRCommentMedia.videoURL(destination) {
            flushInline()
            append(.init(url: url, kind: .video, alt: link.plainText))
            foundMedia = true
          } else {
            inline.append(child.format())
          }
        }
        if foundMedia { flushInline() }
        else { pending.append(block.format()) }
      } else if let html = block as? HTMLBlock, let media = htmlMedia(html.rawHTML) {
        append(media)
      } else {
        pending.append(block.format())
      }
    }
    flush()
    // Preserve exact source, including Markdown spacing, when there is no media.
    return result.contains(where: { if case .media = $0 { true } else { false } }) ? result : [.markdown(source)]
  }

  private static func htmlMedia(_ source: String) -> GitHubPRCommentMedia? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let tag = trimmed.range(of: #"^<(img|video)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
      tag.lowerBound == trimmed.startIndex else { return nil }
    let opening = String(trimmed[tag])
    let remaining = trimmed[tag.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: GitHubPRCommentMedia.Kind = opening.lowercased().hasPrefix("<img") ? .image : .video
    guard remaining.isEmpty || (kind == .video && remaining.lowercased() == "</video>") else { return nil }
    guard let match = opening.range(of: #"\bsrc\s*=\s*(["'][^"']+["'])"#,
      options: [.regularExpression, .caseInsensitive]),
      let equals = opening[match].firstIndex(of: "=") else { return nil }
    let quoted = opening[opening.index(after: equals)..<match.upperBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceURL = String(quoted.dropFirst().dropLast())
    guard let url = GitHubPRCommentMedia.allowedURL(sourceURL) else { return nil }
    return .init(url: url, kind: kind, alt: "")
  }
}
