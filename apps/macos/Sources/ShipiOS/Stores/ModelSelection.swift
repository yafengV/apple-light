import Foundation

extension WorkspaceStore {
  func selectDefaultPower(from catalog: ModelCatalog, taskID: String? = nil) throws {
    guard let selection = catalog.fallbackPowerSelection(advanced: library.enabledAdvancedReasoningEfforts) else {
      throw AgentFailure(message: "当前服务没有可用的默认模型档位。")
    }
    try setModelPickerSelectionMode(.default)
    try selectModel(selection.model, reasoning: selection.reasoningEffort, taskID: taskID)
  }

  func setModelPickerSelectionMode(_ mode: ModelPickerSelectionMode) throws {
    guard library.modelPickerSelectionMode != mode else { return }
    var candidate = library
    candidate.modelPickerSelectionMode = mode
    try commitLibrary(candidate)
  }

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

  func reasoningCommandTarget(_ id: String, taskID: String?) -> String? {
    _ = modelCatalogRevision
    guard let command = ReasoningCommand(id) else { return nil }
    let config = modelConfiguration(for: taskID)
    guard !config.model.isEmpty, (try? config.endpoint("models")) != nil else { return nil }
    let entry = skillModelCatalogs[ModelCatalogSource(config)]?[config.model]
    return command.target(current: config.reasoning, entry: entry)
  }

  func executeReasoningCommand(_ id: String, taskID: String?) {
    guard let target = reasoningCommandTarget(id, taskID: taskID) else { return }
    let config = modelConfiguration(for: taskID)
    let entry = skillModelCatalogs[ModelCatalogSource(config)]?[config.model]
    let effective = ReasoningCommand(id)?.effective(current: config.reasoning, entry: entry)
    guard target != effective else { return }
    do { try selectModel(config.model, reasoning: target, taskID: taskID) }
    catch { self.error = error.localizedDescription }
  }

}
