import SwiftUI

struct SubagentApprovalCard: View {
  let request: SubagentApprovalRequest
  let status: SubagentApprovalStatus?
  let busy: Bool
  let error: String?
  let choose: (Int) -> Void
  private var pending: Bool { status?.turnID == request.turnID && status?.phase == .pending && !busy }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(request.title, systemImage: "hand.raised").appFont(size: 14, weight: .medium)
      if !request.command.isEmpty { Text(request.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
      ForEach(request.paths, id: \.self) { path in Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
      if let reason = request.event["reason"].text { Text(reason).appFont(size: 12).foregroundStyle(.secondary) }
      if let error { Text(error).appFont(size: 12).foregroundStyle(.red).accessibilityIdentifier("subagent-approval-error") }
      if pending {
        ViewThatFits(in: .horizontal) { actions(horizontal: true); actions(horizontal: false) }
      } else {
        Label(busy || status?.phase == .resolving ? "正在提交审批…" : status?.phase == .resolved ? "审批已处理" : "审批已失效",
          systemImage: status?.phase == .resolved ? "checkmark.circle" : "clock")
          .appFont(size: 12).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityIdentifier("subagent-approval:" + request.id)
  }
  private func actions(horizontal: Bool) -> some View {
    let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    return layout {
      ForEach(request.decisions.indices, id: \.self) { index in
        Button(SubagentApprovalRequest.title(request.decisions[index]) ?? "审批") { if pending { choose(index) } }
          .accessibilityIdentifier("subagent-approval-choice:\(index)")
      }
    }
  }
}
