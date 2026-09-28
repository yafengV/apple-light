import Foundation

/// Prompt shorthand only. Skill identities, logical URLs and captured source URLs stay intact.
struct SkillPathAliases: Equatable {
  struct Root: Equatable {
    let name: String
    let path: String
  }
  let roots: [Root]

  static func make(skills: [PluginSkillReference]) -> SkillPathAliases {
    let packaged = skills.filter { !$0.isStandalone && !$0.isRepository }
    let counts = Dictionary(grouping: packaged, by: { $0.catalogRoot?.path ?? "" }).mapValues(\.count)
    var paths: [String] = []
    for skill in skills {
      guard let root = skill.catalogRoot, root.isFileURL else { continue }
      // Single-skill local packages share the installation root, as marketplace packages do in Codex.
      // Directory enumeration can spell /var as /private/var. Match the logical file URL,
      // resolving only the declared root, never the linked skill's target.
      guard let matchingRoot = [root, root.standardizedFileURL, root.resolvingSymlinksInPath()]
        .first(where: { skill.fileURL.path.hasPrefix($0.path + "/") }) else { continue }
      let shared = !skill.isStandalone && !skill.isRepository && counts[root.path] == 1
        && matchingRoot.deletingLastPathComponent().lastPathComponent == "Plugins"
        ? matchingRoot.deletingLastPathComponent() : matchingRoot
      let path = shared.path
      guard path != "/", skill.fileURL.path.hasPrefix(path + "/"), !paths.contains(path) else { continue }
      paths.append(path)
    }
    return .init(roots: paths.enumerated().map { Root(name: "r\($0.offset)", path: $0.element) })
  }

  func shorten(_ path: String) -> String {
    guard let root = roots.filter({ path.hasPrefix($0.path + "/") })
      .max(by: { $0.path.count < $1.path.count }) else { return path }
    return root.name + String(path.dropFirst(root.path.count))
  }

  func expand(_ path: String) -> String? {
    if path.hasPrefix("/") { return path }
    guard let slash = path.firstIndex(of: "/"),
      let root = roots.first(where: { $0.name == String(path[..<slash]) }) else { return nil }
    let suffix = path[path.index(after: slash)...]
    guard !suffix.isEmpty, !suffix.split(separator: "/", omittingEmptySubsequences: false)
      .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    return root.path + "/" + suffix
  }

  var instructions: String {
    guard !roots.isEmpty else { return "" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let rows = roots.map { root in
      let data = try! encoder.encode(["alias": root.name, "path": root.path])
      return "- " + String(decoding: data, as: UTF8.self)
    }
    return "技能路径根目录（本表替代之前回合的别名表）：\n" + rows.joined(separator: "\n")
      + "\npath 中的 rN/前缀是本表的路径缩写；读取前替换为对应绝对根目录，不是实际文件夹或环境变量。仅展开本表定义的别名，技能 id 保持原样；相对资源仍以展开后的技能目录为基准。\n"
  }
}
