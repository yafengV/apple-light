import Foundation

struct GitHubPRGeneratedAttributes: Equatable, Sendable {
  struct Source: Equatable, Sendable { let basePath: String; let contents: String }
  enum Value: Sendable { case set, unset, unspecified }
  let identity: GitHubPRCodeIdentity
  let paths: [String]
  let generated: Set<String>

  init(code: GitHubPRCodeSnapshot, sources: [Source]) throws {
    identity = code.identity; paths = code.files.map(\.path)
    let matchers = try sources.sorted { $0.basePath.count > $1.basePath.count }.map { source in
      (source.basePath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
       try Self.rules(source.contents))
    }
    generated = Set(paths.filter { path in
      let normalized = path.replacingOccurrences(of: "\\", with: "/")
      for (base, rules) in matchers {
        guard base.isEmpty || normalized.hasPrefix(base + "/") else { continue }
        let relative = base.isEmpty ? normalized : String(normalized.dropFirst(base.count + 1))
        var result: Value?
        for rule in rules where rule.matcher.matches(relative) { result = rule.value }
        if let result { return result == .set }
      }
      return false
    })
  }

  private static func rules(_ contents: String) throws -> [(matcher: GeneratedFileGlob, value: Value)] {
    try contents.components(separatedBy: "\n").compactMap { line in
      let text = line.trimmingCharacters(in: ruleWhitespace)
      guard !text.isEmpty, !text.hasPrefix("#"), !text.hasPrefix("[attr]") else { return nil }
      let parts = text.components(separatedBy: ruleWhitespace).filter { !$0.isEmpty }
      guard parts.count > 1 else { return nil }
      let matcher = try GeneratedFileGlob(parts[0])
      var value: Value?
      for attribute in parts.dropFirst() {
        switch attribute {
        case "linguist-generated", "linguist-generated=true": value = .set
        case "-linguist-generated", "linguist-generated=false": value = .unset
        case "!linguist-generated": value = .unspecified
        default: break
        }
      }
      return value.map { (matcher, $0) }
    }
  }

  // ECMAScript trim/\s, including a UTF-8 BOM and excluding U+0085.
  private static let ruleWhitespace = CharacterSet(charactersIn:
    "\u{9}\u{A}\u{B}\u{C}\u{D} \u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

}
