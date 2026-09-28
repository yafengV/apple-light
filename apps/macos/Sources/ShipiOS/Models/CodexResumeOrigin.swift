import Foundation

/// The recorded history namespace for this same task, independent of execution cwd.
struct CodexResumeOrigin {
  let workspace: String
  let threadID: String

  init?(task: WorkspaceTask) {
    guard let workspace = task.codexWorkspacePath, workspace.hasPrefix("/"),
      let threadID = task.codexThreadID, UUID(uuidString: threadID) != nil else { return nil }
    self.workspace = workspace
    self.threadID = threadID
  }

  var wireValue: JSONValue {
    .object(["workspace": .string(workspace), "threadId": .string(threadID)])
  }
}
