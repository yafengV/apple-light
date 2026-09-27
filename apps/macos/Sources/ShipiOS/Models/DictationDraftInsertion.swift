import Foundation

struct DictationCaret {
  let text: String
  let range: NSRange
}

enum DictationDraftInsertion {
  static func apply(_ transcript: String, to current: String,
    initial: String, selection: NSRange?) -> String {
    let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spoken.isEmpty else { return current }
    let range: Range<String.Index>
    if current == initial, let selection, let selected = Range(selection, in: current) {
      range = selected
    } else {
      range = current.endIndex..<current.endIndex
    }
    let before = range.lowerBound == current.startIndex ? nil : current[current.index(before: range.lowerBound)]
    let after = range.upperBound == current.endIndex ? nil : current[range.upperBound]
    let first = spoken.first!
    let last = spoken.last!
    let prefix = needsSpace(before, first) ? " " : ""
    let suffix = needsSpace(last, after) ? " " : ""
    return current.replacingCharacters(in: range, with: prefix + spoken + suffix)
  }

  private static func needsSpace(_ left: Character?, _ right: Character?) -> Bool {
    guard let left, let right else { return false }
    return left.isASCII && right.isASCII
      && (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
  }
}
