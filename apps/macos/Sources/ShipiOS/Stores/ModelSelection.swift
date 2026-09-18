import Foundation

extension WorkspaceStore {
  func openModelPicker() {
    showingBranchPicker = false
    guard (try? modelConfiguration.endpoint("models")) != nil else {
      openSettings(.model)
      return
    }
    presentedOverlay = nil
    destination = .workspace
    action = .chat
    showingModelPicker = true
  }

  func selectModel(_ model: String, reasoning: String) throws {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw AgentFailure(message: "请填写模型 ID。") }
    var config = modelConfiguration
    config.model = model
    config.reasoning = reasoning
    try saveModelConfiguration(config)
  }
}
