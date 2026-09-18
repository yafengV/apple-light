import Foundation

struct TaskWindowRoute: Codable, Hashable, Identifiable {
  let taskID: String
  /// Optional only for decoding windows saved by earlier application versions.
  let dataRoot: String?
  var id: String { taskID }

  init(taskID: String, dataRoot: URL) {
    self.taskID = taskID
    self.dataRoot = Self.workspacePath(dataRoot)
  }

  static func workspacePath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

struct WorkspaceTabWindowRoute: Codable, Hashable, Identifiable {
  let tabID: String
  var id: String { tabID }
}
