import Foundation

/// The public Codex matcher uses Linux minimatch: case-sensitive, dot files,
/// basename matching, and no brace expansion, extglobs, negation or comments.
struct GeneratedFileGlob: Sendable {
  private enum Part: Sendable { case globstar, expression(NSRegularExpression, unicode: Bool) }
  private let parts: [Part]
  private let basename: Bool

  init(_ pattern: String) throws {
    guard pattern.utf16.count <= 65_536 else { throw AgentFailure(message: "生成文件规则的匹配表达式过长，无法完整读取。") }
    basename = !pattern.contains("/")
    parts = try Self.slashes(String(pattern.drop(while: { $0 == "/" }))).map { piece in
      if piece == "**" { return .globstar }
      let unicode = Self.usesUnicodeClass(piece)
      let units = Array(Self.units(piece, unicode: unicode).unicodeScalars)
      var result = "", offset = 0
      while offset < units.count {
        let unit = units[offset]
        switch unit {
        case "*": result += ".*"
        case "?": result += "."
        case "\\":
          if offset + 1 < units.count { offset += 1; result += Self.escape(units[offset]) }
          else { result += Self.escape(unit) }
        case "[":
          if let bracket = Self.bracket(units, at: offset) { result += bracket.regex; offset = bracket.end }
          else { result += Self.escape(unit) }
        default: result += Self.escape(unit)
        }
        offset += 1
      }
      if !piece.isEmpty, piece.allSatisfy({ $0 == "*" }) { result = ".+" }
      // All emitted pieces are escaped literals or validated regular expressions.
      let expression = try NSRegularExpression(pattern: "(?s)\\A(?:" + result + ")\\z")
      return .expression(expression, unicode: unicode)
    }
  }

  func matches(_ path: String) -> Bool {
    var names = Self.slashes(path)
    if basename { names = [names.last(where: { !$0.isEmpty }) ?? ""] }
    var reachable = Set([0])
    for part in parts {
      var next = Set<Int>()
      for start in reachable where start < names.count {
        switch part {
        case .globstar:
          next.insert(start)
          var end = start
          while end < names.count, names[end] != ".", names[end] != ".." { end += 1; next.insert(end) }
        case .expression(let expression, let unicode):
          let name = Self.units(names[start], unicode: unicode)
          if expression.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil {
            next.insert(start + 1)
          }
        }
      }
      reachable = next
      if reachable.isEmpty { return false }
    }
    return reachable.contains(names.count)
  }

  private static func slashes(_ text: String) -> [String] {
    let values = text.components(separatedBy: "/")
    return values.enumerated().compactMap { index, value in
      !value.isEmpty || index == 0 || index == values.count - 1 ? value : nil
    }
  }
  // JavaScript minimatch normally matches UTF-16 units. POSIX Unicode classes
  // enable its Unicode flag. Map surrogate units to two valid private scalars
  // in the former case, without changing text or relying on the process locale.
  private static func units(_ text: String, unicode: Bool) -> String {
    if unicode { return text }
    return String(String.UnicodeScalarView(text.utf16.map {
      UnicodeScalar((0xD800...0xDFFF).contains($0) ? UInt32($0) - 0xD800 + 0xF0000 : UInt32($0))!
    }))
  }
  private static func escape(_ unit: UnicodeScalar) -> String { NSRegularExpression.escapedPattern(for: String(unit)) }
  private static let classes: [String: (regex: String, unicode: Bool, inverted: Bool)] = [
    "[:alnum:]": ("\\p{L}\\p{Nl}\\p{Nd}", true, false), "[:alpha:]": ("\\p{L}\\p{Nl}", true, false),
    "[:ascii:]": ("\\x00-\\x7f", false, false), "[:blank:]": ("\\p{Zs}\\t", true, false),
    "[:cntrl:]": ("\\p{Cc}", true, false), "[:digit:]": ("\\p{Nd}", true, false),
    "[:graph:]": ("\\p{Z}\\p{C}", true, true), "[:lower:]": ("\\p{Ll}", true, false),
    "[:print:]": ("\\p{C}", true, false), "[:punct:]": ("\\p{P}", true, false),
    "[:space:]": ("\\p{Z}\\t\\r\\n\\v\\f", true, false), "[:upper:]": ("\\p{Lu}", true, false),
    "[:word:]": ("\\p{L}\\p{Nl}\\p{Nd}\\p{Pc}", true, false), "[:xdigit:]": ("A-Fa-f0-9", false, false)
  ]
  private static func usesUnicodeClass(_ text: String) -> Bool {
    let units = Array(text.unicodeScalars)
    var offset = 0
    while offset < units.count {
      if units[offset] == "\\" { offset += 2; continue }
      if units[offset] == "[", let result = bracket(units, at: offset) {
        if result.unicode { return true }
        offset = result.end
      }
      offset += 1
    }
    return false
  }
  private static func classEscape(_ unit: UnicodeScalar) -> String {
    // ICU recognizes [:alpha:] inside a regex class; minimatch requires the
    // additional enclosing brackets. Keep literal colons literal in this case.
    if unit == "-" || unit == ":" { return "\\" + String(unit) }
    return escape(unit)
  }
  private static func bracket(_ units: [UnicodeScalar], at start: Int) -> (regex: String, end: Int, unicode: Bool)? {
    var offset = start + 1, positive = "", negative = "", negate = false, hasEntry = false, unicode = false
    if offset < units.count, units[offset] == "!" || units[offset] == "^" { negate = true; offset += 1 }
    while offset < units.count {
      if units[offset] == "]", hasEntry {
        if positive.isEmpty && negative.isEmpty { return ("(?!)", offset, false) }
        let normal = positive.isEmpty ? nil : "[" + (negate ? "^" : "") + positive + "]"
        let inverted = negative.isEmpty ? nil : "[" + (negate ? "" : "^") + negative + "]"
        return ("(?:" + [normal, inverted].compactMap { $0 }.joined(separator: "|") + ")", offset, unicode)
      }
      hasEntry = true
      let remaining = String(String.UnicodeScalarView(units[offset...]))
      if let entry = classes.first(where: { remaining.hasPrefix($0.key) }) {
        unicode = unicode || entry.value.unicode
        if entry.value.inverted { negative += entry.value.regex } else { positive += entry.value.regex }
        offset += entry.key.unicodeScalars.count; continue
      }
      var first = units[offset]
      if first == "\\", offset + 1 < units.count { offset += 1; first = units[offset] }
      if offset + 2 < units.count, units[offset + 1] == "-", units[offset + 2] != "]" {
        var last = units[offset + 2]; offset += 2
        if last == "\\", offset + 1 < units.count { offset += 1; last = units[offset] }
        if first.value < last.value { positive += classEscape(first) + "-" + classEscape(last) }
        else if first == last { positive += classEscape(first) }
      } else { positive += classEscape(first) }
      offset += 1
    }
    return nil // An unclosed bracket is literal text in minimatch.
  }
}
