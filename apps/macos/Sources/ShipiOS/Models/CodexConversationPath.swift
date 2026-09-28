import Foundation
import CryptoKit

enum CodexConversationPath {
  private struct SavedThread: Decodable {
    let threadID: String
    let rolloutPath: String

    enum CodingKeys: String, CodingKey {
      case threadID = "threadId", rolloutPath
      case legacyThreadID = "thread_id", legacyRolloutPath = "rollout_path"
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      threadID = try values.decodeIfPresent(String.self, forKey: .threadID)
        ?? values.decode(String.self, forKey: .legacyThreadID)
      rolloutPath = try values.decodeIfPresent(String.self, forKey: .rolloutPath)
        ?? values.decode(String.self, forKey: .legacyRolloutPath)
    }
  }

  static func existingPath(task: WorkspaceTask, dataRoot: URL) -> URL? {
    guard let expectedThreadID = task.copyableCodexThreadID,
      let taskID = UUID(uuidString: task.id) else { return nil }
    let root = dataRoot.resolvingSymlinksInPath().standardizedFileURL
    if let workspace = task.codexWorkspacePath ?? (task.project.isEmpty ? nil : task.project) {
      let canonical = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
      let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
      let projectData = root.appendingPathComponent("Projects/\(digest)", isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      guard isChild(projectData, of: root) else { return nil }
      // Core now uses a project-owned transport, including projectless task workspaces.
      if let path = privatePath(taskID: taskID, expectedThreadID: expectedThreadID,
        root: projectData) { return path }
      if task.codexWorkspacePath != nil { return nil }
    }
    return privatePath(taskID: taskID, expectedThreadID: expectedThreadID, root: root)
  }

  private static func privatePath(taskID: UUID, expectedThreadID: String, root: URL) -> URL? {
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
