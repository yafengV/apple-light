import Foundation

struct CodeWordRange: Codable, Equatable, Sendable {
  let location: Int
  let length: Int
  var end: Int { location + length }

  static func valid(_ ranges: [Self], in text: String) -> Bool {
    if ranges.isEmpty { return true }
    let units = Array(text.utf16)
    func boundary(_ offset: Int) -> Bool {
      offset == 0 || offset == units.count || !(0xD800...0xDBFF).contains(units[offset - 1])
        || !(0xDC00...0xDFFF).contains(units[offset])
    }
    var previous = 0
    for range in ranges {
      guard range.location >= previous, range.length > 0, range.location <= units.count,
        range.length <= units.count - range.location, boundary(range.location), boundary(range.end) else { return false }
      previous = range.end
    }
    return true
  }
}
