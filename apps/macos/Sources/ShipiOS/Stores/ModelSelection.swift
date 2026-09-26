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

  func selectModel(_ model: String, reasoning: String, taskID: String? = nil) throws {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw AgentFailure(message: "请填写模型 ID。") }
    if let taskID {
      guard libraryLoaded else { throw AgentFailure(message: "工作区尚未加载完成，请稍后再更改模型。") }
      var candidate = library
      guard let index = candidate.tasks.firstIndex(where: { $0.id == taskID }) else {
        throw AgentFailure(message: "这个任务已经不存在，无法更改模型。")
      }
      candidate.tasks[index].modelSelection = TaskModelSelection(model: model, reasoning: reasoning,
        providerAccount: modelConfiguration.credentialAccount,
        apiProtocol: modelConfiguration.apiProtocol)
      try commitLibrary(candidate)
      return
    }
    var config = modelConfiguration
    config.model = model
    config.reasoning = reasoning
    try saveModelConfiguration(config)
  }

  func modelConfiguration(for taskID: String?) -> ModelConfiguration {
    var config = modelConfiguration
    if let taskID, let selection = library.tasks.first(where: { $0.id == taskID })?.modelSelection,
      selection.providerAccount == config.credentialAccount {
      config.model = selection.model
      config.reasoning = selection.reasoning
      config.apiProtocol = selection.apiProtocol ?? .chatCompletions
    }
    return config
  }

}
