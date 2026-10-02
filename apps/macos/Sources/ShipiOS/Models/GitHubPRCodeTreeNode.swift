import Foundation

struct GitHubPRCodeTreeNode: Identifiable {
  struct Row: Identifiable {
    let node: GitHubPRCodeTreeNode
    let depth: Int
    let parentID: String?
    var id: String { node.id }
  }
  let id: String
  let name: String
  let file: GitHubPRCodeFile?
  let children: [Self]
  static func tree(_ files: [GitHubPRCodeFile], prefix: String = "") -> [Self] {
    let groups = Dictionary(grouping: files) { file in
      String(file.path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first ?? "")
    }
    return groups.keys.sorted { left, right in
      let lf = groups[left]?.contains { $0.path == prefix + left } == true
      let rf = groups[right]?.contains { $0.path == prefix + right } == true
      return lf == rf ? left.localizedStandardCompare(right) == .orderedAscending : !lf
    }.map { name in
      let group = groups[name] ?? [], path = prefix + name
      if let file = group.first(where: { $0.path == path }) { return .init(id: path, name: name, file: file, children: []) }
      var children = tree(group, prefix: path + "/")
      var folderPath = path
      var folderName = name
      while children.count == 1, let only = children.first, only.file == nil {
        folderPath = only.id
        folderName += "/" + only.name
        children = only.children
      }
      return .init(id: folderPath, name: folderName, file: nil, children: children)
    }
  }
  static func visibleRows(_ nodes: [Self], collapsed: Set<String>, depth: Int = 0,
    parentID: String? = nil) -> [Row] {
    nodes.flatMap { node in
      let row = Row(node: node, depth: depth, parentID: parentID)
      return node.file == nil && !collapsed.contains(node.id)
        ? [row] + visibleRows(node.children, collapsed: collapsed, depth: depth + 1, parentID: node.id)
        : [row]
    }
  }
}
