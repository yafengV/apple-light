import Foundation

struct CommandBrowserResult: Identifiable, Equatable {
  let id: String
  let owner: String
  let title: String
  let pageTitle: String
  let url: String
  let ownerTitle: String

  static func search(_ tabs: [Self], query: String) -> [Self] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return [] }
    return Array(tabs.filter { tab in
      let text = "\(tab.title)\n\(tab.pageTitle)\n\(tab.url)".lowercased()
      return words.allSatisfy { text.contains($0) }
    }.prefix(10))
  }
}

enum CommandSearchSections {
  /// The first Tab enters the first (or last) search group regardless of arrow selection.
  static func next(_ selection: String?, groups: [[String]], continuing: Bool, reverse: Bool) -> String? {
    let groups = groups.filter { !$0.isEmpty }
    guard groups.count >= 2 else { return nil }
    if continuing, let selection, let index = groups.firstIndex(where: { $0.contains(selection) }) {
      return groups[(index + (reverse ? groups.count - 1 : 1)) % groups.count].first
    }
    return (reverse ? groups.last : groups.first)?.first
  }
}
