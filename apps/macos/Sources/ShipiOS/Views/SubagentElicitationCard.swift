import SwiftUI

struct SubagentElicitationCard: View {
  let request: SubagentElicitationRequest
  let status: SubagentElicitationStatus?
  let busy: Bool
  let error: String?
  let openURL: (URL) -> Void
  let submit: (SubagentElicitationRequest.Choice, JSONValue?) -> Void
  private var pending: Bool { status?.turnID == request.turnID && status?.phase == .pending }
  private var label: String {
    if busy || status?.phase == .resolving { return "正在提交…" }
    if status?.phase == .resolved {
      switch status?.choice { case .accept, .acceptForSession: return "已允许"
      case .decline: return "已拒绝"; case .cancel: return "已取消"; case nil: return "已回答" }
    }
    return pending ? "等待操作" : "已过期"
  }
  var body: some View {
    Group {
      if let issue = request.issue {
        VStack(alignment: .leading, spacing: 12) {
          HStack { Text("MCP · " + request.request.serverName).appFont(.headline); Spacer(); Text(label).appFont(.caption).foregroundStyle(.secondary) }
          Text(request.request.message).textSelection(.enabled)
          Text(issue).appFont(.caption).foregroundStyle(.secondary)
          if let error { Text(error).appFont(.caption).foregroundStyle(.red) }
          if pending {
            HStack { ForEach(request.choices.filter { request.allows($0, content: nil) }, id: \.self) { choice in
              Button(title(choice)) { if pending && !busy { submit(choice, nil) } }
                .accessibilityIdentifier("subagent-elicitation-choice:" + choice.rawValue)
            } }.disabled(busy)
          }
        }.padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      } else if request.isTool {
        VStack(alignment: .leading, spacing: 12) {
          HStack { Text("允许子任务使用 MCP 工具？").appFont(.headline); Spacer(); Text(label).foregroundStyle(.secondary).appFont(.caption) }
          Text(request.request.serverName).appFont(.caption).foregroundStyle(.secondary)
          Text(request.request.message).textSelection(.enabled)
          if let error { Text(error).foregroundStyle(.red).appFont(.caption) }
          if pending {
            ViewThatFits(in: .horizontal) { buttons; VStack(alignment: .leading, spacing: 8) { choices } }
              .disabled(busy)
          }
        }.padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      } else {
        CodexElicitationCard(request: request.request, pending: pending, busy: busy, statusLabel: label,
          error: error, verificationURL: request.verificationURL, openURL: openURL,
          submit: { accepted, content in submit(accepted ? .accept : (request.request.isURLRequest ? .cancel : .decline), content) })
          .id(request.id)
      }
    }.accessibilityIdentifier("subagent-elicitation:" + request.id)
  }
  private var buttons: some View { HStack(spacing: 8) { choices } }
  private var choices: some View {
    ForEach(request.choices, id: \.self) { choice in
      Button(title(choice)) { if pending && !busy { submit(choice, nil) } }
        .accessibilityIdentifier("subagent-elicitation-choice:" + choice.rawValue)
    }
  }
  private func title(_ choice: SubagentElicitationRequest.Choice) -> String {
    switch choice { case .accept: "允许一次"; case .acceptForSession: "允许此会话"; case .decline: "拒绝"; case .cancel: "取消" }
  }
}
