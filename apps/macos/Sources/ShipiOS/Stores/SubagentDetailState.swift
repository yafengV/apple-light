import Foundation
import Observation

@MainActor @Observable final class SubagentDetailState {
  private(set) var selected: CodexSubagent?
  private(set) var transcript = SubagentTranscript()
  private(set) var loading = false
  private(set) var sending = false
  private(set) var error: String?
  var draft = ""
  private var generation = UUID()
  private var history: [JSONValue] = []
  private var live: SubagentLiveState?

  func updateLive(_ state: SubagentLiveState?) {
    live = state; rebuild()
  }

  private func rebuild() {
    transcript = .init(events: live?.merged(with: history) ?? history)
  }

  func select(_ agent: CodexSubagent?) {
    generation = UUID(); selected = agent; transcript = .init(); history = []; live = nil
    draft = ""; loading = false; sending = false; error = nil
  }

  func update(_ agent: CodexSubagent) {
    if agent.id == selected?.id { selected = agent }
  }

  func load(using read: (CodexSubagent) async throws -> [JSONValue]) async {
    guard let agent = selected else { return }
    let token = generation
    loading = transcript.entries.isEmpty
    defer { if token == generation { loading = false } }
    do {
      let events = try await read(agent)
      guard token == generation, !Task.isCancelled else { return }
      history = events; rebuild(); error = nil
    } catch {
      guard token == generation, !Task.isCancelled, !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }

  func send(working: Bool, using submit: (CodexSubagent, String, String?) async throws -> String) async -> Bool {
    guard let agent = selected, agent.acceptsInput, !sending,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !working || transcript.activeTurnID != nil else { return false }
    let token = generation, text = draft
    sending = true
    defer { if token == generation { sending = false } }
    do {
      _ = try await submit(agent, text, working ? transcript.activeTurnID : nil)
      guard token == generation, !Task.isCancelled else { return false }
      if draft == text { draft = "" }
      error = nil; sending = false
      return true
    } catch {
      guard token == generation, !Task.isCancelled else { return false }
      self.error = error.localizedDescription; sending = false
      return false
    }
  }
}
