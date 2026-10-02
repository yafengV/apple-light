import Foundation

/// Resolves Markdown references against the file in the exact PR head revision.
struct GitHubPRMarkdownContext: Equatable, Sendable {
  let repository: String
  let head: String
  let filePath: String

  init?(pullRequestURL: URL?, head: String, filePath: String) {
    guard let url = pullRequestURL, [40, 64].contains(head.utf8.count),
      head.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
      Self.validRepositoryPath(filePath) else { return nil }
    let parts = url.pathComponents
    guard parts.count >= 3 else { return nil }
    repository = parts[1] + "/" + parts[2]
    self.head = head
    self.filePath = filePath
  }

  func path(for reference: String) -> String? {
    guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.hasPrefix("\\"),
      !reference.hasPrefix("//"), !reference.contains("\\"),
      let first = reference.first, first != "#", first != "?" else { return nil }
    let raw = String(reference.prefix { $0 != "#" && $0 != "?" })
    guard !raw.isEmpty, let decoded = raw.removingPercentEncoding,
      !decoded.hasPrefix("/"), !decoded.hasPrefix("\\"), !decoded.contains("\\"),
      !decoded.contains(":"), !decoded.contains("\0") else { return nil }
    var parts = Array(filePath.split(separator: "/").dropLast()).map(String.init)
    for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
      if part.isEmpty || part == "." { continue }
      if part == ".." {
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
      } else { parts.append(String(part)) }
    }
    let resolved = parts.joined(separator: "/")
    return Self.validRepositoryPath(resolved) ? resolved : nil
  }

  func link(for reference: String) -> URL? {
    if reference.hasPrefix("#") { return blobURL(path: filePath, suffix: reference) }
    guard let path = path(for: reference) else { return nil }
    let suffix = reference.firstIndex(where: { $0 == "?" || $0 == "#" }).map { String(reference[$0...]) } ?? ""
    return blobURL(path: path, suffix: suffix)
  }

  private func blobURL(path: String, suffix: String) -> URL? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
    let encoded = path.split(separator: "/").map {
      String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }.joined(separator: "/")
    return URL(string: "https://github.com/\(repository)/blob/\(head)/\(encoded)\(suffix)")
  }

  static func validRepositoryPath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
      !path.contains("\0") && !path.contains("//") && !path.hasSuffix("/") &&
      path.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}
