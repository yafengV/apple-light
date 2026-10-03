import Foundation

enum ModelAutomationPauseTool {
  static let name = "shipios_pause_automation"
  static let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
  static var wire: JSONValue {
    .object(["type": .string("function"), "function": .object([
      "name": .string(name),
      "description": .string("Pause only the PR heartbeat attached to this thread before your final response when it is complete or blocked by unavailable credentials, access or a user decision. Report the exact reason and ask one concise question in the thread if input is needed. This does not interrupt the current turn or create, resume or change any other automation."),
      "parameters": .object(["type": .string("object"), "properties": .object([
        "reason": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)]),
      ]), "required": .array([.string("reason")]), "additionalProperties": .bool(false)]),
    ])])
  }
}
