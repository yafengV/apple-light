import Foundation

enum ModelPickerSelectionMode: String, Codable {
  case `default`, model
}

struct ModelPowerSelection: Equatable, Identifiable {
  let model: String
  let reasoningEffort: String
  let powerSettingIndex: Int
  var id: String { "\(model):\(reasoningEffort)" }
}

extension ModelCatalog {
  /// The public client's fallback presets. Every stop still requires explicit
  /// capability metadata from this service; these names never imply availability.
  func defaultPowerSelections(advanced: Set<AgentAdvancedReasoningEffort>,
    removeXHigh: Bool = false) -> [ModelPowerSelection] {
    let primary = [("gpt-5.6-terra", "low")] + ["low", "medium", "high", "xhigh", "ultra"]
      .map { ("gpt-5.6-sol", $0) }
    let secondary = ["low", "medium", "high", "xhigh"].map { ("gpt-5.6-terra", $0) }
    let allowed = Set(AgentReasoningEfforts.available(advanced: advanced))
    func resolve(_ preset: [(String, String)]) -> [ModelPowerSelection] {
      preset.filter { !removeXHigh || $0.1 != "xhigh" }.enumerated().compactMap { index, pair in
        guard models.contains(pair.0), allowed.contains(pair.1),
          supportedReasoningEfforts[pair.0]?.contains(pair.1) == true else { return nil }
        return ModelPowerSelection(model: pair.0, reasoningEffort: pair.1, powerSettingIndex: index)
      }
    }
    let first = resolve(primary)
    if first.count >= 3 { return first }
    let second = resolve(secondary)
    return second.count >= 3 ? second : []
  }

  func powerSelections(for model: String, current: String,
    mode: ModelPickerSelectionMode?, advanced: Set<AgentAdvancedReasoningEffort>) -> [ModelPowerSelection] {
    let defaults = defaultPowerSelections(advanced: advanced)
    let effective = current.isEmpty ? defaultReasoningEffort(for: model) ?? "medium" : current
    if mode != .model, defaults.contains(where: { $0.model == model && $0.reasoningEffort == effective }) {
      return defaults
    }
    return powerChoices(for: model, advanced: advanced).enumerated().map {
      ModelPowerSelection(model: model, reasoningEffort: $0.element, powerSettingIndex: $0.offset)
    }
  }

  func selectedPower(in selections: [ModelPowerSelection], model: String, reasoning: String) -> ModelPowerSelection? {
    let effective = reasoning.isEmpty ? defaultReasoningEffort(for: model) ?? "medium" : reasoning
    return selections.first { $0.model == model && $0.reasoningEffort == effective }
  }

  func fallbackPowerSelection(advanced: Set<AgentAdvancedReasoningEffort>) -> ModelPowerSelection? {
    let selections = defaultPowerSelections(advanced: advanced)
    return selections.first { $0.model.contains("-sol") && $0.reasoningEffort == "medium" }
      ?? selections.first { $0.model.contains("-sol") }
      ?? selections.first { $0.reasoningEffort == "medium" } ?? selections.first
  }
}
