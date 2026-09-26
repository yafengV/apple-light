import Foundation

struct CodexPlanStep: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", completed }
  let step: String
  let status: Status
}

struct CodexPlan: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let explanation: String?
  let steps: [CodexPlanStep]

  static func update(_ event: JSONValue, existing: Self?) throws -> Self {
    guard event["type"].text == "plan_update" else {
      throw AgentFailure(message: "Codex 计划事件格式无效。")
    }
    let steps = try event["plan"].decode([CodexPlanStep].self)
    guard steps.count <= 100,
      steps.allSatisfy({ !$0.step.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.step.utf8.count <= 4096 }) else {
      throw AgentFailure(message: "Codex 计划步骤无效。")
    }
    return Self(id: existing?.id ?? UUID(), explanation: event["explanation"].text,
      steps: steps)
  }
}

extension AgentRun {
  var codexPlan: CodexPlan? { try? result?["codex_plan"].decode(CodexPlan.self) }
}
