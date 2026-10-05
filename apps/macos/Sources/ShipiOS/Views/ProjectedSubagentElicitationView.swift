import SwiftUI

struct ProjectedSubagentElicitationView: View {
  let store: WorkspaceStore
  let taskID: String
  let presentation: SubagentElicitationPresentation
  var body: some View {
    let agent = presentation.agent, request = presentation.request
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        SubagentAvatar(agent: agent)
        Text(agent.displayName).appFont(size: 13, weight: .medium)
      }
      SubagentElicitationCard(request: request, status: store.subagentLiveStates[agent.id]?.elicitations[request.id],
        busy: store.subagentElicitationBusy.contains(request.id), error: store.subagentElicitationErrors[request.id],
        openURL: { store.performMessageLinkAction(.openExternal, url: $0,
          ownerRunID: store.library.tasks.first { $0.id == taskID }?.runIDs.last) },
        submit: { choice, content in
          Task { await store.resolveSubagentElicitation(taskID: taskID, agent: agent, request: request, choice: choice, content: content) }
        })
    }.accessibilityIdentifier("projected-subagent-elicitation:" + presentation.id)
  }
}
