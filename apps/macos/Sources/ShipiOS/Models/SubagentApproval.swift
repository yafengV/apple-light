import Foundation

struct SubagentApprovalRequest: Equatable, Identifiable {
  let id: String
  let turnID: String
  let event: JSONValue
  let decisions: [JSONValue]
  init?(_ event: JSONValue) {
    guard ["exec_approval_request", "apply_patch_approval_request"].contains(event["type"].text ?? ""),
      let token = event["shipios_approval"]["token"].text, UUID(uuidString: token) != nil,
      let turn = event["turn_id"].text, !turn.isEmpty,
      case .array(let decisions) = event["shipios_approval"]["decisions"], !decisions.isEmpty,
      decisions.allSatisfy({ Self.title($0) != nil }) else { return nil }
    id = token; turnID = turn; self.event = event; self.decisions = decisions
  }
  var title: String { event["type"].text == "apply_patch_approval_request" ? "允许子任务修改文件？" : "允许子任务执行命令？" }
  var command: String { event["command"].items.compactMap(\.text).joined(separator: " ") }
  var paths: [String] { if case .object(let changes) = event["changes"] { return changes.keys.sorted() }; return [] }
  static func title(_ decision: JSONValue) -> String? {
    switch decision.text {
    case "approved": return "允许一次"
    case "approved_for_session": return "允许此会话"
    case "approved_mcp_policy_amendment": return "允许并记住工具规则"
    case "abort": return "拒绝并停止"
    case "timed_out": return "超时"
    default:
      if case .object = decision["approved_execpolicy_amendment"] { return "允许并记住命令规则" }
      if case .object = decision["denied"] { return "拒绝" }
      if case .object = decision["network_policy_amendment"] {
        return decision["network_policy_amendment"]["network_policy_amendment"]["action"].text == "deny" ? "阻止此域名" : "允许此域名"
      }
      return nil
    }
  }
}

struct SubagentApprovalStatus: Equatable {
  enum Phase: String { case pending, resolving, resolved, expired }
  let turnID: String
  let revision: Int
  let phase: Phase
}
