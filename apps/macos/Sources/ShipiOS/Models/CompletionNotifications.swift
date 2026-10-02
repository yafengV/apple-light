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

enum TaskNotificationKind: String, Codable {
  case completion, approval, question
}

struct CompletionNotificationPreferences: Codable, Equatable {
  var timing: CompletionNotificationTiming = .background
  var promptForPermission = false
  var approvalAlertsEnabled = true
  var questionAlertsEnabled = true
  init(timing: CompletionNotificationTiming = .background, promptForPermission: Bool = false,
    approvalAlertsEnabled: Bool = true, questionAlertsEnabled: Bool = true) {
    self.timing = timing
    self.promptForPermission = promptForPermission
    self.approvalAlertsEnabled = approvalAlertsEnabled
    self.questionAlertsEnabled = questionAlertsEnabled
  }
  private enum CodingKeys: String, CodingKey {
    case timing, promptForPermission, approvalAlertsEnabled, questionAlertsEnabled
  }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    timing = try values.decodeIfPresent(CompletionNotificationTiming.self, forKey: .timing) ?? .background
    promptForPermission = try values.decodeIfPresent(Bool.self, forKey: .promptForPermission) ?? false
    approvalAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .approvalAlertsEnabled) ?? true
    questionAlertsEnabled = try values.decodeIfPresent(Bool.self, forKey: .questionAlertsEnabled) ?? true
  }
  func permits(_ kind: TaskNotificationKind, appIsActive: Bool) -> Bool {
    switch kind {
    case .completion: timing == .always || (timing == .background && !appIsActive)
    case .approval: approvalAlertsEnabled
    case .question: questionAlertsEnabled
    }
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
  var kind: TaskNotificationKind = .completion
  private static func scope(_ root: URL) -> String {
    SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func turn(_ run: AgentRun, task: WorkspaceTask, root: URL) -> Self {
    return Self(
      id: "\(scope(root)):\(run.id)", title: run.status == "succeeded" ? "任务已完成" : "任务失败",
      body: task.title,
      destination: NotificationDestination(dataRoot: root.path, project: run.project, taskID: task.id, runID: run.id))
  }
  static func attention(_ kind: TaskNotificationKind, eventID: UUID,
    run: AgentRun, task: WorkspaceTask, root: URL) -> Self {
    Self(id: "\(scope(root)):\(run.id):\(kind.rawValue):\(eventID.uuidString)",
      title: kind == .approval ? "需要批准操作" : "需要回答问题",
      body: task.title,
      destination: NotificationDestination(dataRoot: root.path, project: run.project,
        taskID: task.id, runID: run.id), kind: kind)
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
