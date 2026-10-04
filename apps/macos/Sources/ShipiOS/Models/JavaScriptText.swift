import Foundation

/// ECMAScript String.trim and \s include BOM, and exclude U+0085/U+200B.
enum JavaScriptText {
  static let whitespace = CharacterSet(charactersIn:
    "\u{9}\u{A}\u{B}\u{C}\u{D} \u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}"
      + "\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
  static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: whitespace) }
}
