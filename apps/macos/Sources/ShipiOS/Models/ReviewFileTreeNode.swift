import Foundation

/// A tree of recorded diff paths. It never resolves or opens a filesystem path.
struct ReviewFileTreeNode: Identifiable, Equatable {
  let id: String
  let name: String
  let path: String?
  let children: [Self]

  struct Row: Identifiable {
    let node: ReviewFileTreeNode
    let depth: Int
    let parentID: String?
    var id: String { node.id }
  }

  static func tree(paths: [String], query: String) -> [Self] {
    let matches = ReviewFileJump.matches(paths: Array(Set(paths)), query: query)
    let entries = matches.map { match -> (String, [String]) in
      var parts = match.path.split(separator: "/").map(String.init)
      if match.path.hasPrefix("/") { parts.insert("/", at: 0) }
      return (match.path, parts)
    }.filter { !$0.1.isEmpty }
    return build(entries, prefix: "")
  }

  private static func build(_ entries: [(String, [String])], prefix: String) -> [Self] {
    let groups = Dictionary(grouping: entries) { $0.1[0] }
    var nodes: [Self] = []
    for name in groups.keys.sorted() {
      let group = groups[name] ?? []
      let location = prefix.isEmpty ? name : prefix == "/" ? prefix + name : prefix + "/" + name
      // A deleted file and a newly added directory can share a prefix. Keep both.
      for leaf in group where leaf.1.count == 1 {
        nodes.append(.init(id: "file:" + leaf.0, name: name, path: leaf.0, children: []))
      }
      let nested = group.filter { $0.1.count > 1 }.map { ($0.0, Array($0.1.dropFirst())) }
      if !nested.isEmpty {
        nodes.append(.init(id: "folder:" + location, name: name, path: nil,
          children: build(nested, prefix: location)))
      }
    }
    return nodes.sorted {
      if ($0.path == nil) != ($1.path == nil) { return $0.path == nil }
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  static func rows(_ nodes: [Self], collapsed: Set<String>, depth: Int = 0,
    parentID: String? = nil) -> [Row] {
    nodes.flatMap { node in
      let row = Row(node: node, depth: depth, parentID: parentID)
      return node.path == nil && !collapsed.contains(node.id)
        ? [row] + rows(node.children, collapsed: collapsed, depth: depth + 1, parentID: node.id)
        : [row]
    }
  }
}
