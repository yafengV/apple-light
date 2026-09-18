import Foundation

/// Archive search uses a complete query against each field, with edit distance
/// at most 40% of its UTF-16 length and no penalty for position in the field.
/// Long queries use overlapping 32-unit chunks, matching Fuse's archive options.
struct ArchivedTaskSearch {
  private let chunks: [[UInt16]]
  // ECMAScript String.trim differs from Foundation's whitespace set (notably
  // BOM and U+0085). Keep pasted queries consistent with the reference UI.
  private static let queryWhitespace = CharacterSet(charactersIn:
    "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}"
      + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
      + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

  init(_ query: String) {
    let units = Array(query.trimmingCharacters(in: Self.queryWhitespace).lowercased().utf16)
    if units.count <= 32 {
      chunks = units.isEmpty ? [] : [units]
    } else {
      var values = stride(from: 0, through: units.count - 32, by: 32).map {
        Array(units[$0..<($0 + 32)])
      }
      if units.count % 32 != 0 { values.append(Array(units.suffix(32))) }
      chunks = values
    }
  }

  func matches(_ fields: [String]) -> Bool {
    guard !chunks.isEmpty else { return true }
    return fields.contains { field in
      let text = Array(field.lowercased().utf16)
      guard !text.isEmpty else { return false }
      return chunks.contains { matches($0, in: text) }
    }
  }

  // Semiglobal edit distance: consuming a prefix of the field is free, while
  // substitutions, insertions and deletions within the query each cost one.
  // Two short rows keep memory bounded even for a long title or pasted query.
  private func matches(_ pattern: [UInt16], in text: [UInt16]) -> Bool {
    let limit = Int(floor(Double(pattern.count) * 0.4))
    var previous = Array(0...pattern.count)
    var current = [Int](repeating: 0, count: pattern.count + 1)
    for unit in text {
      current[0] = 0
      for index in 1...pattern.count {
        current[index] = min(previous[index] + 1, current[index - 1] + 1,
          previous[index - 1] + (unit == pattern[index - 1] ? 0 : 1))
      }
      if current[pattern.count] <= limit { return true }
      swap(&previous, &current)
    }
    return false
  }
}
