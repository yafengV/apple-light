import Foundation
import OSLog

enum WorkspaceStopTarget: Equatable {
  case run(runID: String, taskID: String?)
  case background(taskID: String, terminalID: UUID, threadID: String)
  case descendants(taskID: String, threadID: String, childIDs: Set<String>)
}

extension WorkspaceStore {
  /// Resolve before scheduling an asynchronous action, while its window still
  /// owns the selection. Never resolve a captured target again after switching.
  func stopTarget(taskID: String? = nil) -> WorkspaceStopTarget? {
    let owner = taskID ?? selectedTask?.id
    if let owner {
      if let run = activeRun(taskID: owner) { return .run(runID: run.id, taskID: owner) }
      if let threadID = library.tasks.first(where: { $0.id == owner })?.codexThreadID,
        let terminal = backgroundTerminals(taskID: owner).first(where: { $0.threadID == threadID }) {
        guard !backgroundTerminalCleanupRequests.contains(owner) else { return nil }
        return .background(taskID: owner, terminalID: terminal.id, threadID: terminal.threadID)
      }
      if let threadID = library.tasks.first(where: { $0.id == owner })?.codexThreadID {
        let children = activeSubagents(taskID: owner)
        if !children.isEmpty { return .descendants(taskID: owner, threadID: threadID,
          childIDs: Set(children.map(\.threadID))) }
      }
    }
    // The main window can also stop its local build/diagnostic run. A task
    // window must never fall back to another task's run.
    if taskID == nil, let run = activeLocalRun {
      return .run(runID: run.id, taskID: library.task(containing: run.id)?.id)
    }
    return nil
  }

  @discardableResult func requestStop(taskID: String? = nil) -> Task<Void, Never>? {
    guard let target = stopTarget(taskID: taskID) else { return nil }
    return Task { await performStop(target) }
  }

  func cancel(taskID: String? = nil) async {
    guard let target = stopTarget(taskID: taskID) else { return }
    await performStop(target)
  }

  func performStop(_ target: WorkspaceStopTarget) async {
    switch target {
    case let .run(runID, taskID):
      let run: AgentRun?
      if let taskID { run = activeRun(taskID: taskID).flatMap { $0.id == runID ? $0 : nil } }
      else { run = runs.first { $0.id == runID && $0.isActive } }
      guard let run else { return }
      if let taskID { pauseGoal(taskID) }
      if run.kind == "chat" {
        modelTask(runID: run.id)?.cancel()
      } else {
        do { _ = try await client.request("run.cancel", ["runId": .string(run.id)]) }
        catch { self.error = error.localizedDescription }
      }
    case let .background(taskID, terminalID, threadID):
      // A shortcut captured while idle cannot clean commands belonging to a
      // new turn, a replacement thread, or an already-ended process.
      guard activeRun(taskID: taskID) == nil,
        library.tasks.first(where: { $0.id == taskID })?.codexThreadID == threadID,
        backgroundTerminals(taskID: taskID).contains(where: {
          $0.id == terminalID && $0.threadID == threadID
        }) else { return }
      pauseGoal(taskID)
      let childIDs = Set(activeSubagents(taskID: taskID).map(\.threadID))
      do { try await submitBackgroundTerminalCleanup(taskID: taskID) }
      catch {
        // The reference shortcut fallback logs failure; explicit row cleanup
        // separately owns its visible spinner and error notification.
        Logger(subsystem: "dev.shipios.desktop", category: "TaskStop")
          .warning("Background terminal stop fallback failed: \(error.localizedDescription, privacy: .private)")
      }
      await stopIdleDescendants(taskID: taskID, threadID: threadID,
        childIDs: childIDs)
    case let .descendants(taskID, threadID, childIDs):
      await stopIdleDescendants(taskID: taskID, threadID: threadID, childIDs: childIDs)
    }
  }

  private func stopIdleDescendants(taskID: String, threadID: String, childIDs: Set<String>) async {
    guard !childIDs.isEmpty, activeRun(taskID: taskID) == nil,
      library.tasks.first(where: { $0.id == taskID })?.codexThreadID == threadID,
      !childIDs.isDisjoint(with: activeSubagents(taskID: taskID).map(\.threadID)) else { return }
    pauseGoal(taskID)
    do { try await codexTransport.interruptDescendants(taskID: taskID, expectedThreadID: threadID) }
    catch {
      Logger(subsystem: "dev.shipios.desktop", category: "TaskStop")
        .warning("Subagent stop fallback failed: \(error.localizedDescription, privacy: .private)")
    }
  }
}
