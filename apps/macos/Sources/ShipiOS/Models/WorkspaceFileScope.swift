import Foundation

struct WorkspaceFileLocation: Equatable {
  let root: URL
  let path: String
  var url: URL { root.appendingPathComponent(path) }
}

enum WorkspaceFileScope {
  static func roots(primary: URL?, additional: [URL]) -> [URL] {
    guard let primary else { return [] }
    var seen = Set<String>()
    return ([primary] + additional).map { $0.resolvingSymlinksInPath().standardizedFileURL }
      .filter { seen.insert($0.path).inserted }
  }

  /// Resolve against the currently attached roots, including symlink destinations.
  static func location(_ path: String, roots: [URL]) throws -> WorkspaceFileLocation {
    guard let primary = roots.first, !path.contains("\0") else {
      throw AgentFailure(message: "请先选择项目。")
    }
    let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
      : primary.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
    guard let root = roots.first(where: { candidate.path.hasPrefix($0.path + "/") }) else {
      throw AgentFailure(message: "文件不在当前项目关联的文件夹内。")
    }
    return .init(root: root, path: String(candidate.path.dropFirst(root.path.count + 1)))
  }

  static func key(_ location: WorkspaceFileLocation, primary: URL) -> String {
    location.root == primary ? location.path : location.url.path
  }
}

struct WorkspaceFileGroup: Identifiable {
  let root: URL
  let paths: [String]
  var id: String { root.path }
}
