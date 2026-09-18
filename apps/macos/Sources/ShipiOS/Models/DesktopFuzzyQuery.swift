import Foundation

struct FuzzyTextMatch: Equatable {
  let score: Int
  /// UTF-16 offsets, matching AppKit and the desktop client's search protocol.
  let ranges: [NSRange]
}

/// Case-insensitive word-boundary matching used by desktop task and command search.
struct DesktopFuzzyQuery {
  private let main: FuzzyPattern
  private let fallback: FuzzyPattern?
  private let usesPath: Bool
  private let empty: Bool

  init(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    empty = trimmed.isEmpty
    let normalized = trimmed.unicodeScalars.map { scalar -> String in
      let original = String(scalar), lower = String(scalar).lowercased()
      return lower.utf16.count == original.utf16.count ? lower : original
    }.joined()
    usesPath = normalized.contains("/") || normalized.contains("\\")
    var pattern = "*" + normalized
    if usesPath { pattern = pattern.replacingOccurrences(of: "/", with: "*\0*").replacingOccurrences(of: "\\", with: "*\0*") }
    main = FuzzyPattern(pattern)
    var lastSeparator: String.Index?
    for separator: Character in ["/", "\\"] {
      if let index = normalized.lastIndex(of: separator), normalized.index(after: index) < normalized.endIndex,
        lastSeparator == nil || index > lastSeparator! { lastSeparator = index }
    }
    fallback = usesPath && lastSeparator != nil
      ? FuzzyPattern(String(normalized[normalized.index(after: lastSeparator!)...])) : nil
  }

  func match(_ text: String) -> FuzzyTextMatch? {
    guard !empty else { return nil }
    let original = Array(text.utf16)
    let name = usesPath ? original.map { $0 == 47 || $0 == 92 ? UInt16(0) : $0 } : original
    for pattern in [main, fallback].compactMap({ $0 }) {
      let matcher = FuzzyMatcher(pattern: pattern, name: name)
      if let ranges = matcher.match() {
        let degree = matcher.degree(ranges) + (ranges.first?.lowerBound == 0 ? 10_000 : 0)
        return .init(score: max(1, degree * 10 - original.count),
          ranges: ranges.map { NSRange(location: $0.lowerBound, length: $0.count) })
      }
    }
    return nil
  }
}

private struct FuzzyPattern {
  let units: [UInt16]
  let lower: [UInt16?]
  let upper: [UInt16?]
  let isLower: [Bool]
  let isUpper: [Bool]
  let separators: [Bool]
  let meaningful: [Int]
  let mixedCase: Bool
  let hasSeparators: Bool
  let hasDots: Bool

  init(_ input: String) {
    let input = input.hasSuffix("* ") ? String(input.dropLast(2)) : input
    let units = Array(input.utf16)
    let lower = units.map { FuzzyCharacters.cased($0, upper: false) }
    let upper = units.map { FuzzyCharacters.cased($0, upper: true) }
    let isLower = units.indices.map { lower[$0] == units[$0] && upper[$0] != units[$0] }
    let isUpper = units.indices.map { upper[$0] == units[$0] && lower[$0] != units[$0] }
    let separators = units.map { FuzzyCharacters.separator($0) }
    let meaningful = units.indices.filter { units[$0] != 32 && units[$0] != 42 }
    let first = meaningful.first ?? units.count
    mixedCase = isLower.contains(true) && units.indices.contains { $0 > first && isUpper[$0] }
    hasSeparators = units.indices.contains { $0 >= first && separators[$0] }
    hasDots = units.contains(46)
    self.units = units; self.lower = lower; self.upper = upper
    self.isLower = isLower; self.isUpper = isUpper
    self.separators = separators; self.meaningful = meaningful
  }
  func wildcard(_ index: Int) -> Bool { has(index, 32) || has(index, 42) }
  func has(_ index: Int, _ value: UInt16) -> Bool { units.indices.contains(index) && units[index] == value }
  func equals(_ index: Int, _ value: UInt16) -> Bool {
    units.indices.contains(index) && (units[index] == value || lower[index] == value || upper[index] == value)
  }
}

private enum FuzzyCharacters {
  static func cased(_ unit: UInt16, upper: Bool) -> UInt16? {
    guard let scalar = UnicodeScalar(unit) else { return unit }
    let mapped = upper ? String(scalar).uppercased() : String(scalar).lowercased()
    return mapped.utf16.count == 1 ? mapped.utf16.first : nil
  }
  static func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
  static func alphanumeric(_ unit: UInt16) -> Bool {
    digit(unit) || (65...90).contains(unit) || (97...122).contains(unit)
  }
  static func uppercase(_ unit: UInt16) -> Bool { cased(unit, upper: true) == unit && cased(unit, upper: false) != unit }
  static func lowercase(_ unit: UInt16) -> Bool { cased(unit, upper: false) == unit && cased(unit, upper: true) != unit }
  static func separator(_ unit: UInt16) -> Bool {
    if [95, 45, 58, 43, 46, 47, 92].contains(unit) { return true }
    return UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
  }
  static func wordStart(_ text: [UInt16], _ index: Int) -> Bool {
    guard text.indices.contains(index), alphanumeric(text[index]) else { return false }
    if index == 0 { return true }
    let before = text[index - 1], current = text[index]
    return !alphanumeric(before) || uppercase(current) && lowercase(before) || digit(current) && !digit(before)
  }
}

private final class FuzzyMatcher {
  let p: FuzzyPattern
  let name: [UInt16]
  var failed = Set<Int>()
  init(pattern: FuzzyPattern, name: [UInt16]) { p = pattern; self.name = name }

  func match() -> [Range<Int>]? {
    guard name.count >= p.meaningful.count else { return nil }
    if p.units.count > 100 { return substring() }
    var next = 0
    for index in name.indices where next < p.meaningful.count {
      if p.equals(p.meaningful[next], name[index]) {
        let previous = p.units.count - 2
        if next == p.meaningful.count - 1, previous >= 0,
          FuzzyCharacters.alphanumeric(p.units[previous + 1]), !p.wildcard(previous),
          (index == 0 || !p.equals(previous, name[index - 1])), !FuzzyCharacters.wordStart(name, index) { continue }
        next += 1
      }
    }
    guard next == p.meaningful.count else { return nil }
    return wildcards(0, 0)?.reversed()
  }

  private func substring() -> [Range<Int>]? {
    let literal = p.units.filter { $0 != 42 }
    let needle = String(decoding: literal, as: UTF16.self).lowercased()
    let text = String(decoding: name, as: UTF16.self).lowercased() as NSString
    if p.has(0, 42) {
      let range = text.range(of: needle)
      return range.location != NSNotFound && range.location + literal.count <= name.count
        ? [range.location..<(range.location + literal.count)] : nil
    }
    return String(decoding: name.prefix(literal.count), as: UTF16.self).lowercased() == needle
      ? [0..<literal.count] : nil
  }

  private func occurrence(_ start: Int, _ index: Int) -> Int? {
    guard start < name.count else { return nil }
    let wordOnly = !p.has(index - 1, 42) && !p.separators[index]
    if wordOnly, p.mixedCase, p.isLower[index], !(index > 0 && p.separators[index - 1]) { return nil }
    return (max(0, start)..<name.count).first {
      p.equals(index, name[$0]) && (!wordOnly || !FuzzyCharacters.alphanumeric(p.units[index]) || FuzzyCharacters.wordStart(name, $0))
    }
  }

  private func checked(_ from: Int, _ next: Int?, _ index: Int) -> Int? {
    guard let next else { return nil }
    if from < next {
      let skipped = name[from..<next]
      if !p.hasSeparators && !p.mixedCase && skipped.contains(where: { $0 == 47 || $0 == 92 }) { return nil }
      if p.hasDots && !p.has(index - 1, 46) && skipped.contains(46) { return nil }
    }
    return next
  }

  private func wildcards(_ index: Int, _ offset: Int) -> [Range<Int>]? {
    guard !Task.isCancelled else { return nil }
    var index = index
    if !p.wildcard(index) { return index == p.units.count ? [] : fragment(index, offset) }
    repeat { index += 1 } while p.wildcard(index)
    if index == p.units.count {
      if p.has(p.units.count - 1, 32), offset != name.count,
        index < 2 || !(p.isUpper[index - 2] || FuzzyCharacters.digit(p.units[index - 2])) {
        return name.indices.dropFirst(offset).first(where: { name[$0] == 32 }).map { [$0..<($0 + 1)] }
      }
      return []
    }
    return skipping(index, occurrence(offset, index), freely: true)
  }

  private func skipping(_ index: Int, _ offset: Int?, freely: Bool) -> [Range<Int>]? {
    guard let offset, !Task.isCancelled else { return nil }
    let state = (index * (name.count + 1) + offset) * 2 + (freely ? 1 : 0)
    guard !failed.contains(state) else { return nil }
    var current: Int? = offset, longest = 0
    while let start = current {
      let possible = !p.isUpper[index] || FuzzyCharacters.uppercase(name[start]) || FuzzyCharacters.wordStart(name, start) || !p.mixedCase
      let length = possible ? fragmentLength(index, start) : 0
      if length > longest || start + length == name.count && p.has(p.units.count - 1, 32) {
        if !middle(index, start) { longest = length }
        if let result = inside(index, start, length) { return result }
      }
      let next = occurrence(start + 1, index)
      current = freely ? next : checked(start + 1, next, index)
    }
    failed.insert(state)
    return nil
  }

  private func fragment(_ index: Int, _ offset: Int) -> [Range<Int>]? {
    let length = fragmentLength(index, offset)
    return length == 0 ? nil : inside(index, offset, length)
  }
  private func fragmentLength(_ index: Int, _ offset: Int) -> Int {
    guard offset < name.count, p.equals(index, name[offset]) else { return 0 }
    var count = 1
    while offset + count < name.count && index + count < p.units.count {
      if !p.equals(index + count, name[offset + count]) {
        if FuzzyCharacters.digit(p.units[index + count]), FuzzyCharacters.digit(p.units[index + count - 1]),
          FuzzyCharacters.digit(name[offset + count]) { return 0 }
        break
      }
      count += 1
    }
    return count
  }
  private func middle(_ index: Int, _ offset: Int) -> Bool {
    p.has(index - 1, 42) && !p.wildcard(index + 1) && FuzzyCharacters.alphanumeric(name[offset]) && !FuzzyCharacters.wordStart(name, offset)
  }
  private func inside(_ index: Int, _ offset: Int, _ length: Int) -> [Range<Int>]? {
    let minimum = middle(index, offset) ? 3 : 1
    if minimum < length {
      for count in minimum..<length where p.isUpper[index + count] && p.units[index + count] != name[offset + count] {
        if let next = occurrence(offset + count, index + count), let rest = wildcards(index + count, next) {
          return joined(rest, offset, count)
        }
      }
    }
    return longestPrefix(index, offset, length, minimum)
  }
  private func longestPrefix(_ index: Int, _ offset: Int, _ length: Int, _ minimum: Int) -> [Range<Int>]? {
    if index + length >= p.units.count { return [offset..<(offset + length)] }
    var length = length
    while length >= minimum || length > 0 && p.wildcard(index + length) {
      let rest: [Range<Int>]?
      if p.wildcard(index + length) { rest = wildcards(index + length, offset + length) }
      else { rest = skipping(index + length, checked(offset + length, occurrence(offset + length + 1, index + length), index + length), freely: false) }
      if let rest { return joined(rest, offset, length) }
      length -= 1
    }
    return nil
  }
  private func joined(_ ranges: [Range<Int>], _ offset: Int, _ length: Int) -> [Range<Int>] {
    var ranges = ranges
    if let last = ranges.last, last.lowerBound == offset + length { ranges[ranges.count - 1] = offset..<last.upperBound }
    else { ranges.append(offset..<(offset + length)) }
    return ranges
  }

  func degree(_ ranges: [Range<Int>]) -> Int {
    guard let first = ranges.first else { return 0 }
    var score = 0, patternIndex = -1, skippedWords = 0, boundary = 0, uppercaseWord = false
    for (fragmentIndex, range) in ranges.enumerated() {
      for offset in range {
        let newFragment = offset == range.lowerBound && fragmentIndex != 0
        var atBoundary = false
        while boundary <= offset {
          if boundary == offset { atBoundary = true } else if newFragment { skippedWords += 1 }
          if boundary < name.count && FuzzyCharacters.digit(name[boundary]) { boundary += 1 }
          else { boundary = ((boundary + 1)..<max(boundary + 1, name.count)).first { FuzzyCharacters.wordStart(name, $0) } ?? (name.count + 1) }
        }
        let value = name[offset]
        let lower = FuzzyCharacters.cased(value, upper: false), upper = FuzzyCharacters.cased(value, upper: true)
        guard let next = p.units.indices.dropFirst(patternIndex + 1).first(where: { p.units[$0] == lower || p.units[$0] == upper }) else { break }
        patternIndex = next
        if atBoundary { uppercaseWord = value == p.units[next] && p.isUpper[next] }
        if newFragment && atBoundary && p.isLower[next] { score -= 10 }
        else if value == p.units[next] { score += p.isUpper[next] ? 50 : (atBoundary ? 1 : 0) }
        else if atBoundary || p.isLower[next] && uppercaseWord { score -= 1 }
      }
    }
    let start = first.lowerBound
    let wordPrefix = start == 0 || FuzzyCharacters.wordStart(name, start) && !FuzzyCharacters.wordStart(name, start - 1)
    let afterSeparator = name.prefix(start).contains { $0 == 47 || $0 == 92 }
    return (wordPrefix ? 1000 : 0) + score - ranges.count - skippedWords * 10
      + (afterSeparator ? 0 : 2) + (start == 0 ? 1 : 0) + (ranges.last?.upperBound == name.count ? 1 : 0)
  }
}
