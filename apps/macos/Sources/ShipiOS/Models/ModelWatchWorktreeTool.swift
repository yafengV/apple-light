import Foundation

enum ModelWatchWorktreeTool {
  static let name = "shipios_request_pr_worktree"
  static var wire: JSONValue {
    .object(["type": .string("function"), "function": .object([
      "name": .string(name),
      "description": .string("Request an isolated worktree for this PR heartbeat only after logs prove an authorized code change or conflict resolution is needed. Supply the specific reason. During inspection this records the request, without creating a checkout yet. Finish this read-only turn; ShipiOS will create the isolated worktree and continue this same thread there. Never claim creation or modify the configured checkout. If a worktree already exists, the result returns its path."),
      "parameters": .object(["type": .string("object"), "properties": .object([
        "reason": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)]),
      ]), "required": .array([.string("reason")]), "additionalProperties": .bool(false)]),
    ])])
  }
}
