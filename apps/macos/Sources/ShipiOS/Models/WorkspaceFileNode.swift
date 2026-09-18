import Foundation

struct WorkspaceFileNode: Identifiable {
  let path: String
  let children: [WorkspaceFileNode]?
  var id: String { path }
  var title: String { URL(fileURLWithPath: path).lastPathComponent }
  static func tree(_ paths: [String], prefix: String = "") -> [Self] {
    let groups = Dictionary(grouping: paths) { path in
      String(path.dropFirst(prefix.count).split(separator: "/").first ?? "")
    }
    return groups.keys.filter { !$0.isEmpty }.map { name in
      let full = prefix + name
      let values = groups[name]!
      let directory = values.contains { $0.hasPrefix(full + "/") }
      return Self(path: full, children: directory ? tree(values, prefix: full + "/") : nil)
    }.sorted {
      if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }
}
