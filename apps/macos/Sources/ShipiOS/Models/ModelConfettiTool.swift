import Foundation

enum ModelConfettiTool {
  static let name = "shipios_fire_confetti"

  static var wire: JSONValue {
    .object(["type": .string("function"), "function": .object([
      "name": .string(name),
      "description": .string("Fire a short confetti celebration in ShipiOS only when the user asks for confetti or explicitly invites a celebration. Do not use this for routine task completion."),
      "parameters": .object([
        "type": .string("object"), "properties": .object([:]),
        "additionalProperties": .bool(false),
      ]),
    ])])
  }
}
