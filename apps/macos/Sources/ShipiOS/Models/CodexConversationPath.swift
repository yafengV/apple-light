import Foundation

enum CodexConversationPath {
  private struct SavedThread: Decodable {
    let threadID: String
    let rolloutPath: String

    enum CodingKeys: String, CodingKey {
      case threadID = "thread_id"
      case rolloutPath = "rollout_path"
    }
  }

  static func existingPath(task: WorkspaceTask, dataRoot: URL) -> URL? {
    guard let expectedThreadID = task.copyableCodexThreadID,
      let taskID = UUID(uuidString: task.id) else { return nil }
    let root = dataRoot.resolvingSymlinksInPath().standardizedFileURL
    let home = root.appendingPathComponent("Codex/Tasks", isDirectory: true)
      .appendingPathComponent(taskID.uuidString.lowercased(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard isChild(home, of: root) else { return nil }
    let reference = home.appendingPathComponent("thread.json").resolvingSymlinksInPath().standardizedFileURL
    guard isChild(reference, of: home), isRegularFile(reference),
      let data = try? Data(contentsOf: reference),
      let thread = try? JSONDecoder().decode(SavedThread.self, from: data),
      UUID(uuidString: thread.threadID) == UUID(uuidString: expectedThreadID),
      (thread.rolloutPath as NSString).isAbsolutePath else { return nil }
    let rollout = URL(fileURLWithPath: thread.rolloutPath)
      .resolvingSymlinksInPath().standardizedFileURL
    guard isChild(rollout, of: home), isRegularFile(rollout) else { return nil }
    return rollout
  }

  private static func isChild(_ url: URL, of parent: URL) -> Bool {
    url.path.hasPrefix(parent.path + "/")
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
}
