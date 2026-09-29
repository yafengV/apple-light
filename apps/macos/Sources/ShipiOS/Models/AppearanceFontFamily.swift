import Foundation

/// Mirrors the first-family parser used by the distributed settings picker.
/// Rendering uses the whole list; selection and its label use only the first item.
enum AppearanceFontFamily {
  static let generics: Set<String> = ["-apple-system", "blinkmacsystemfont", "monospace", "sans-serif", "serif", "system-ui", "ui-monospace", "ui-sans-serif"]
  static func trimmed(_ value: String) -> String {
    let whitespace = CharacterSet(charactersIn: "\u{9}\u{a}\u{b}\u{c}\u{d}\u{20}\u{a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    return value.trimmingCharacters(in: whitespace)
  }
  private static func rawItems(_ value: String) -> [String] {
    let units = Array(value.utf16); var start = 0, index = 0, quote: UInt16?, result: [String] = []
    while index < units.count {
      let unit = units[index]
      if unit == 92 { index += 1 }
      else if let active = quote { if unit == active { quote = nil } }
      else if unit == 34 || unit == 39 { quote = unit }
      else if unit == 44 { result.append(trimmed(String(decoding: units[start..<index], as: UTF16.self))); start = index + 1 }
      index += 1
    }
    result.append(trimmed(String(decoding: units[start...], as: UTF16.self))); return result
  }
  private static func unquote(_ value: String) -> String {
    var chars = Array(value.unicodeScalars)
    if chars.first == "\"" || chars.first == "'" { chars.removeFirst() }
    if chars.last == "\"" || chars.last == "'" { chars.removeLast() }
    var result = "", index = 0
    while index < chars.count {
      if chars[index] == "\\", index + 1 < chars.count { index += 1 }
      result.unicodeScalars.append(chars[index]); index += 1
    }
    return result
  }
  static func first(_ value: String?) -> String? {
    guard let value, let raw = rawItems(value).first else { return nil }
    let name = unquote(raw); return name.isEmpty ? nil : name
  }
  static func displayName(_ value: String?) -> String? {
    guard let name = first(value), !generics.contains(name.lowercased()) else { return nil }; return name
  }
  static func names(_ value: String) -> [String] { rawItems(value).map(unquote).filter { !$0.isEmpty } }
  static func quote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
