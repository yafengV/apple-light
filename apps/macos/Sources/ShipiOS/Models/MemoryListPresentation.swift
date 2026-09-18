import Foundation

enum MemoryListSort: String, CaseIterable {
  case newest, oldest
  var title: String { self == .newest ? "最新优先" : "最早优先" }
}

/// Filtering never changes the underlying collection or the scope of Delete All.
struct MemoryListPresentation {
  enum State: Equatable { case loading, failed, empty, noMatches(String), ready }
  let items: [SavedMemory]
  let state: State

  init(preferences: MemoryPreferences, loaded: Bool, loading: Bool, query: String,
    sort: MemoryListSort) {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard loaded, !loading else {
      items = []
      state = loading ? .loading : .failed
      return
    }
    items = preferences.items.filter { Self.matches($0.text, query: query) }.sorted {
      if $0.updatedAt != $1.updatedAt {
        return sort == .newest ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt
      }
      return $0.id.uuidString < $1.id.uuidString
    }
    state = items.isEmpty ? (query.isEmpty ? .empty : .noMatches(query)) : .ready
  }

  /// Approximate substring search, independent of the match's location in a memory.
  /// Allow the same 0.4 relative edit threshold used by the reference manager.
  static func matches(_ text: String, query: String) -> Bool {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    let needle = query.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
    let haystack = text.folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
    if needle.isEmpty || haystack.contains(needle) { return true }
    let pattern = Array(needle), content = Array(haystack)
    let allowance = Int(Double(pattern.count) * 0.4)
    guard allowance > 0, pattern.count - content.count <= allowance else { return false }
    // Each text prefix may start a match; only the pattern prefix incurs a cost.
    var previous = Array(repeating: 0, count: content.count + 1)
    for (index, character) in pattern.enumerated() {
      var current = Array(repeating: index + 1, count: content.count + 1)
      for (offset, candidate) in content.enumerated() {
        current[offset + 1] = min(previous[offset + 1] + 1, current[offset] + 1,
          previous[offset] + (character == candidate ? 0 : 1))
      }
      if current.min()! > allowance { return false }
      previous = current
    }
    return previous.min()! <= allowance
  }
}
