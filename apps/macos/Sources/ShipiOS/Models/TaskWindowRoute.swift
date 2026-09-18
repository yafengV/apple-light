import Foundation

struct TaskWindowRoute: Codable, Hashable, Identifiable {
  let taskID: String
  var id: String { taskID }
}

struct WorkspaceTabWindowRoute: Codable, Hashable, Identifiable {
  let tabID: String
  var id: String { tabID }
}
