import Foundation

/// A live Core command identity. Process lifetime is never reconstructed from history.
struct CodexBackgroundTerminal: Identifiable, Equatable {
  let id: UUID
  let taskID: String
  let runID: String
  let threadID: String
  let turnID: String
  let callID: String
  let processID: String?
  let command: String
  var bytes: Data
  var running = true
  var cleanupRequested = false
  var output: String { String(decoding: bytes, as: UTF8.self) }
  var title: String { command.isEmpty ? "后台终端" : command }

  static func command(_ event: JSONValue) -> String {
    for item in event["parsed_cmd"].items.reversed() {
      if let command = item["cmd"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
        return command
      }
    }
    let argv = event["command"].items.compactMap(\.text)
    if argv.count >= 3, ["sh", "bash", "zsh", "fish"].contains(URL(fileURLWithPath: argv[0]).lastPathComponent),
      argv[1].hasPrefix("-"), argv[1].contains("c") { return argv[2] }
    return argv.joined(separator: " ")
  }
}

struct CodexBackgroundTerminalDocument: Equatable {
  let id: UUID
  let title: String
  let output: String
}
