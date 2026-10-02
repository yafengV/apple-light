import Foundation

enum GitHubPRCodeFileJump {
  struct Match: Identifiable, Equatable {
    let path: String
    let fileName: String
    let parentPath: String
    let score: Int
    var id: String { path }
  }

  static func matches(paths: [String], query: String) -> [Match] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matcher = DesktopFuzzyQuery(search)
    let items = paths.map { path -> Match in
      let fileName = (path as NSString).lastPathComponent
      let parentPath = (path as NSString).deletingLastPathComponent
      let score = search.isEmpty ? 0
        : matcher.match(fileName)?.score ?? matcher.match(path)?.score ?? 0
      return .init(path: path, fileName: fileName,
        parentPath: parentPath == "." ? "" : parentPath, score: score)
    }
    return items.filter { search.isEmpty || $0.score > 0 }.sorted { left, right in
      if !search.isEmpty, left.score != right.score { return left.score > right.score }
      let names = left.fileName.localizedStandardCompare(right.fileName)
      if names != .orderedSame { return names == .orderedAscending }
      let parents = left.parentPath.localizedStandardCompare(right.parentPath)
      if parents != .orderedSame { return parents == .orderedAscending }
      return left.path < right.path
    }
  }
}
