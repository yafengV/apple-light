import Foundation

enum ModelPickerSelectionMode: String, Codable {
  case `default`, model
}

struct ModelPowerSelection: Equatable, Identifiable {
  let model: String
  let reasoningEffort: String
  let powerSettingIndex: Int
  var id: String { "\(model):\(reasoningEffort)" }

  static func fallback(in selections: [Self], preferredID: String?) -> Self? {
    let effort = preferredID.map { id in
      guard let separator = id.lastIndex(of: ":") else { return id }
      return String(id[id.index(after: separator)...])
    }
    return selections.first { $0.id == preferredID }
      ?? selections.first { $0.isSol && $0.reasoningEffort == effort }
      ?? selections.first { $0.isSol && $0.reasoningEffort == "medium" }
      ?? selections.first { $0.isSol }
      ?? selections.first { $0.reasoningEffort == "medium" } ?? selections.first
  }

  private var isSol: Bool {
    model.range(of: "(?:^|[-_.])sol(?:$|[-_.])", options: [.regularExpression, .caseInsensitive]) != nil
  }
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
    let preferred = models.compactMap { details[$0] }.first { $0.isDefault == true }
    let preferredID = preferred.flatMap { entry in entry.defaultReasoningEffort.map { "\(entry.id):\($0)" } }
    return ModelPowerSelection.fallback(in: selections, preferredID: preferredID)
  }
}
