import Foundation

enum ReviewFileJump {
  struct Target: Equatable {
    let anchor: String
    let collapseKey: String
  }

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

  static func target(path: String, scope: GitReviewScope, root: URL?, selection: String,
    revision: String,
    files: [GitFile], lastTurn: LastTurnReviewSnapshot?) -> Target? {
    if scope == .lastTurn {
      guard let snapshot = lastTurn,
        let file = snapshot.files.first(where: { $0.path == path }) else { return nil }
      return .init(anchor: snapshot.source.runID + ":" + String(file.id),
        collapseKey: "lastTurn:" + snapshot.source.runID + ":" + file.path)
    }
    guard let root, files.contains(where: { $0.path == path }) else { return nil }
    return .init(anchor: root.path + ":" + selection + ":" + path,
      collapseKey: scope.rawValue + ":" + revision + ":" + path)
  }
}
