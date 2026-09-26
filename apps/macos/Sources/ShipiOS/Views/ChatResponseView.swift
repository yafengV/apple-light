import SwiftUI

/// Shared by the main conversation and independent task windows.
struct ChatResponseView: View {
  @Environment(\.messageBrowserRoute) private var openInApp
  let store: WorkspaceStore
  let run: AgentRun

  var body: some View {
    let ordered = run.responseItems
    let executions = run.toolExecutions
    ForEach(ordered ?? run.displayedResponseItems) { item in
      switch item {
      case .message(_, let text):
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          MessageMarkdownView(source: text, runID: run.id,
            partPrefix: ordered == nil ? "response" : item.searchPrefix,
            linkActions: MessageLinkActions(
              activate: { url, click in
                store.openMessageLink(url, project: store.workspaceRoot(for: run), ownerRunID: run.id, click: click, openInApp: openInApp)
              },
              perform: { url, action in store.performMessageLinkAction(action, url: url, ownerRunID: run.id, openInApp: openInApp) }
            )) { url in
              store.openMessageLink(url, project: store.workspaceRoot(for: run), ownerRunID: run.id,
                click: WebLinkClick(event: NSApp.currentEvent), openInApp: openInApp)
            }
        }
      case .tool(let id):
        if let execution = executions.first(where: { $0.id == id }) {
          MCPToolExecutionView(store: store, run: run, execution: execution)
        }
      case .question(let id):
        if let question = run.codexQuestions.first(where: { $0.id == id }) {
          CodexQuestionView(store: store, run: run, request: question)
        }
      case .elicitation(let id):
        if let request = run.codexElicitations.first(where: { $0.id == id }) {
          CodexElicitationView(store: store, run: run, request: request)
        }
      case .plan(let id):
        if let plan = run.codexPlan, plan.id == id {
          CodexPlanView(plan: plan)
        }
      case .user(let id):
        if let message = run.codexSteeredMessages.first(where: { $0.id == id }) {
          CodexSteeredMessageView(store: store, runID: run.id, message: message)
        }
      }
    }
  }
}
