import Foundation

enum GoalResponseSignal: Equatable {
  case continueWorking
  case complete
}

struct ParsedGoalResponse: Equatable {
  let text: String
  let signal: GoalResponseSignal?
}

enum GoalResponseParser {
  static let continuationPrompt =
    "继续执行这个目标。根据成功标准检查当前进度，完成剩余工作并运行必要验证。"

  static func parse(_ response: String) -> ParsedGoalResponse {
    var lines = response.components(separatedBy: .newlines)
    var signal: GoalResponseSignal?
    if let index = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      switch lines[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "shipios_goal_status: continue": signal = .continueWorking
      case "shipios_goal_status: complete": signal = .complete
      default: break
      }
      if signal != nil { lines.remove(at: index) }
    }
    return ParsedGoalResponse(
      text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
      signal: signal)
  }
}

extension WorkspaceStore {
  func goalSession(for taskID: String?) -> GoalSession? {
    taskID.flatMap { library.goalSessions[$0] }
  }

  var composerGoalDefinition: GoalDefinition? {
    goalSession(for: selectedTask?.id)?.definition ?? pendingGoal
  }

  @discardableResult
  func configureGoal(_ value: GoalDefinition, taskID explicitTaskID: String? = nil) -> Bool {
    let definition = value.normalized
    guard !definition.objective.isEmpty, !definition.successCriteria.isEmpty else {
      error = "请填写目标，并至少添加一条成功标准。"
      return false
    }
    let taskID = explicitTaskID ?? selectedTask?.id
    if let taskID {
      guard library.tasks.contains(where: { $0.id == taskID }) else {
        error = "这个任务已经不存在。"
        return false
      }
      library.goalSessions[taskID] = GoalSession(definition: definition)
      pendingGoal = nil
      saveLibrary()
    } else {
      pendingGoal = definition
    }
    if explicitTaskID == nil || selectedTask?.id == taskID {
      action = .chat
      chatMode = .goal
    }
    error = nil
    focusComposer = UUID()
    return true
  }

  func clearPendingGoal() {
    pendingGoal = nil
    if chatMode == .goal { chatMode = .standard }
  }

  func leaveGoalMode() {
    if let taskID = selectedTask?.id,
      library.goalSessions[taskID]?.status == .active
    {
      pauseGoal(taskID)
    } else if selectedTask == nil {
      clearPendingGoal()
    }
    chatMode = .standard
  }

  func pauseGoal(_ taskID: String) {
    guard var session = library.goalSessions[taskID], session.status == .active else { return }
    session.status = .paused
    library.goalSessions[taskID] = session
    if selectedTask?.id == taskID { chatMode = .standard }
    saveLibrary()
  }

  func completeGoal(_ taskID: String) {
    guard var session = library.goalSessions[taskID] else { return }
    session.status = .completed
    library.goalSessions[taskID] = session
    if selectedTask?.id == taskID { chatMode = .standard }
    saveLibrary()
  }

  func resumeGoal(_ taskID: String) async {
    guard var session = library.goalSessions[taskID], canStartChat(taskID: taskID) else { return }
    if session.iteration >= session.definition.maxIterations { session.iteration = 0 }
    session.status = .active
    library.goalSessions[taskID] = session
    if selectedTask?.id == taskID { chatMode = .goal }
    saveLibrary()
    await startChat(GoalResponseParser.continuationPrompt, taskID: taskID, mode: .goal)
  }
}
