import Foundation

struct GitHubPRCommentMedia: Sendable, Equatable {
  enum Kind: Sendable, Equatable { case image, video }
  let url: URL
  let kind: Kind
  let alt: String
  let title: String?
  init(url: URL, kind: Kind, alt: String, title: String? = nil) {
    self.url = url; self.kind = kind; self.alt = alt; self.title = title
  }

  static func mightContainURL(_ source: String) -> Bool {
    let text = source.lowercased()
    return text.contains("github.com/user-attachments/assets/") ||
      text.contains("user-images.githubusercontent.com/") ||
      text.contains("private-user-images.githubusercontent.com/")
  }

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

  static func html(_ source: String) -> Self? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let tag = trimmed.range(of: #"^<(img|video)\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
      tag.lowerBound == trimmed.startIndex else { return nil }
    let opening = String(trimmed[tag])
    let remaining = trimmed[tag.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: Kind = opening.lowercased().hasPrefix("<img") ? .image : .video
    guard remaining.isEmpty || (kind == .video && remaining.lowercased() == "</video>") else { return nil }
    guard let sourceURL = attribute("src", in: opening), let url = allowedURL(sourceURL) else { return nil }
    return .init(url: url, kind: kind, alt: attribute("alt", in: opening) ?? "", title: attribute("title", in: opening))
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    guard let match = tag.range(of: #"\b"# + name + #"\s*=\s*(["'][^"']*["'])"#,
      options: [.regularExpression, .caseInsensitive]),
      let equals = tag[match].firstIndex(of: "=") else { return nil }
    let quoted = tag[tag.index(after: equals)..<match.upperBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return decodeHTMLEntities(String(quoted.dropFirst().dropLast()))
  }

  private static func decodeHTMLEntities(_ source: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"&(?:#[xX][0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt);"#,
      options: .caseInsensitive) else { return source }
    let nsSource = source as NSString
    let matches = expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
    var result = source
    for match in matches.reversed() {
      let entity = nsSource.substring(with: match.range)
      let key = String(entity.dropFirst().dropLast()).lowercased()
      let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
      let value: String?
      if key.hasPrefix("#x"), let scalar = UInt32(key.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init) {
        value = String(scalar)
      } else if key.hasPrefix("#"), let scalar = UInt32(key.dropFirst(), radix: 10).flatMap(UnicodeScalar.init) {
        value = String(scalar)
      } else { value = named[key] }
      if let value, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
    }
    return result
  }
}
