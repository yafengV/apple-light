import Foundation

extension AgentRun {
  var codexSteeredMessages: [QueuedMessage] {
    (try? result?["codex_steered_messages"].decode([QueuedMessage].self)) ?? []
  }
}
