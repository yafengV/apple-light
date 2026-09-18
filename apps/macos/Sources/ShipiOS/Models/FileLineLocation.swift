import Foundation

enum FileLineLocation {
  /// NSString offsets match NSTextView, including emoji and CRLF files.
  static func range(_ input: String, in text: String) -> NSRange? {
    guard let line = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)), line > 0 else { return nil }
    let source = text as NSString
    var start = 0
    var number = 1
    while number < line {
      guard start < source.length else { return nil }
      start = NSMaxRange(source.lineRange(for: NSRange(location: start, length: 0)))
      number += 1
    }
    if start == source.length {
      guard text.isEmpty || text.last?.isNewline == true else { return nil }
      return NSRange(location: start, length: 0)
    }
    var end = 0
    source.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
    return NSRange(location: start, length: end - start)
  }
}
