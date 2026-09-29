import Foundation

struct GitHubPRCodeTreeNode: Identifiable {
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
      return .init(id: path, name: name, file: nil, children: tree(group, prefix: path + "/"))
    }
  }
}
