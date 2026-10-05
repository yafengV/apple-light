import Foundation

extension WorkspaceStore {
  func subagentElicitations(taskID: String, includeResolving: Bool = true) -> [SubagentElicitationPresentation] {
    guard let task = library.tasks.first(where: { $0.id == taskID }), !task.archived,
      let root = task.codexThreadID else { return [] }
    return subagents(taskID: taskID).filter { $0.rootThreadID == root && $0.loaded }.flatMap { agent -> [SubagentElicitationPresentation] in
      guard let live = subagentLiveStates[agent.id], live.error == nil else { return [] }
      return live.events.compactMap(SubagentElicitationRequest.init).filter { request in
        guard let status = live.elicitations[request.id], status.turnID == request.turnID else { return false }
        return status.phase == .pending || (includeResolving && status.phase == .resolving)
      }.map { SubagentElicitationPresentation(agent: agent, request: $0) }
    }
  }

  func subagentAttention(taskID: String) -> TaskAttentionKind? {
    guard let task = library.tasks.first(where: { $0.id == taskID }), !task.archived,
      let root = task.codexThreadID else { return nil }
    let agents = subagents(taskID: taskID).filter { $0.rootThreadID == root && $0.loaded }
    if agents.contains(where: { agent in
      guard let live = subagentLiveStates[agent.id], live.error == nil else { return false }
      return live.events.compactMap(SubagentApprovalRequest.init).contains { request in
        live.approvals[request.id]?.turnID == request.turnID && live.approvals[request.id]?.phase == .pending
      }
    }) { return .approval }
    let requests = subagentElicitations(taskID: taskID, includeResolving: false)
    if requests.contains(where: { $0.request.isTool }) { return .approval }
    return requests.isEmpty ? nil : .elicitation
  }

  func notifySubagentRequests(taskID: String) {
    guard let task = library.tasks.first(where: { $0.id == taskID }), !task.archived,
      let root = task.codexThreadID,
      let run = task.runIDs.reversed().compactMap({ id in library.chatRuns.first { $0.id == id } }).first else { return }
    for agent in subagents(taskID: taskID) where agent.rootThreadID == root && agent.loaded {
      guard let live = subagentLiveStates[agent.id], live.error == nil else { continue }
      let approvals = live.events.compactMap(SubagentApprovalRequest.init).filter {
        live.approvals[$0.id]?.turnID == $0.turnID && live.approvals[$0.id]?.phase == .pending
      }.map { ($0.id, TaskNotificationKind.approval, false) }
      let forms = live.events.compactMap(SubagentElicitationRequest.init).filter {
        live.elicitations[$0.id]?.turnID == $0.turnID && live.elicitations[$0.id]?.phase == .pending
      }.map { ($0.id, $0.isTool ? TaskNotificationKind.approval : .question, true) }
      for (token, kind, projected) in approvals + forms {
        guard let eventID = UUID(uuidString: token), subagentNotifiedRequests.insert(agent.id + ":" + token).inserted else { continue }
        notifyAttention(runID: run.id, kind: kind, eventID: eventID,
          subagent: projected ? .init(rootThreadID: root, childThreadID: agent.threadID, requestToken: token) : nil)
      }
    }
  }
}
