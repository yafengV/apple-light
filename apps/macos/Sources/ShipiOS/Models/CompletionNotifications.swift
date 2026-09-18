import CryptoKit
import Foundation

enum CompletionNotificationTiming: String, Codable, CaseIterable, Identifiable {
  case background, always, never
  var id: String { rawValue }
  var title: String {
    switch self {
    case .background: "应用在后台时"
    case .always: "始终"
    case .never: "从不"
    }
  }
}

struct CompletionNotificationPreferences: Codable, Equatable {
  var timing: CompletionNotificationTiming = .background
  var promptForPermission = false
  func permits(appIsActive: Bool) -> Bool {
    timing == .always || (timing == .background && !appIsActive)
  }
}

struct NotificationDestination: Equatable {
  let dataRoot: String
  let project: String
  let taskID: String
  let runID: String
  var userInfo: [String: String] {
    ["dataRoot": dataRoot, "project": project, "taskID": taskID, "runID": runID]
  }
  init(dataRoot: String, project: String, taskID: String, runID: String) {
    self.dataRoot = dataRoot; self.project = project; self.taskID = taskID; self.runID = runID
  }
  init?(userInfo: [AnyHashable: Any]) {
    guard let root = userInfo["dataRoot"] as? String,
      let project = userInfo["project"] as? String,
      let task = userInfo["taskID"] as? String,
      let run = userInfo["runID"] as? String,
      !root.isEmpty, !task.isEmpty, !run.isEmpty
    else { return nil }
    self.init(dataRoot: root, project: project, taskID: task, runID: run)
  }
}

struct CompletionNotice: Equatable {
  let id: String
  let title: String
  let body: String
  let destination: NotificationDestination?
  static func turn(_ run: AgentRun, task: WorkspaceTask, root: URL) -> Self {
    let scope = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
    return Self(
      id: "\(scope):\(run.id)", title: run.status == "succeeded" ? "任务已完成" : "任务失败",
      body: task.title,
      destination: NotificationDestination(dataRoot: root.path, project: run.project, taskID: task.id, runID: run.id))
  }
}

struct CompletionTracker {
  private var active: Set<String> = []
  private var finished: Set<String> = []
  mutating func seed(_ runs: [AgentRun]) {
    for run in runs {
      if run.isActive { begin(run.id) }
      else { finished.insert(run.id); active.remove(run.id) }
    }
  }
  mutating func begin(_ id: String) {
    if !finished.contains(id) { active.insert(id) }
  }
  mutating func completed(_ run: AgentRun) -> Bool {
    if run.isActive { begin(run.id); return false }
    guard active.remove(run.id) != nil, finished.insert(run.id).inserted else { return false }
    return ["succeeded", "failed"].contains(run.status)
  }
}
