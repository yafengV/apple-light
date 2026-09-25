import Foundation

struct TaskWindowRoute: Codable, Hashable, Identifiable {
  let taskID: String
  /// Optional only for decoding windows saved by earlier application versions.
  let dataRoot: String?
  let windowID: String?
  var id: String { windowID ?? taskID }

  init(taskID: String, dataRoot: URL, windowID: String? = nil) {
    self.taskID = taskID
    self.dataRoot = Self.workspacePath(dataRoot)
    self.windowID = windowID ?? taskID
  }

  static func workspacePath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}

struct WorkspaceTabWindowRoute: Codable, Hashable, Identifiable {
  let tabID: String
  let owner: String?
  let dataRoot: String?
  var id: String { tabID }

  init(tabID: String, owner: String? = nil, dataRoot: URL? = nil) {
    self.tabID = tabID
    self.owner = owner
    self.dataRoot = dataRoot.map(TaskWindowRoute.workspacePath)
  }
}
