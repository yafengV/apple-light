import Foundation
import Observation
import CoreFoundation

struct ModelCatalogEntry: Equatable {
  let id: String
  let supportedReasoningEfforts: Set<String>?
  let reasoningOrder: [String]?
  let displayName: String?
  let description: String?
  let defaultReasoningEffort: String?
  let priority: Int?
  let showInPicker: Bool?
  let contextWindow: Int?

  init(id: String, supportedReasoningEfforts: Set<String>? = nil,
    reasoningOrder: [String]? = nil,
    displayName: String? = nil, description: String? = nil,
    defaultReasoningEffort: String? = nil, priority: Int? = nil,
    showInPicker: Bool? = nil, contextWindow: Int? = nil) {
    self.id = id
    self.supportedReasoningEfforts = supportedReasoningEfforts
    if let reasoningOrder {
      var seen = Set<String>()
      self.reasoningOrder = reasoningOrder.filter { seen.insert($0).inserted }
    } else if let supportedReasoningEfforts {
      let known = AgentReasoningEfforts.available(advanced: Set(AgentAdvancedReasoningEffort.allCases))
      self.reasoningOrder = known.filter { supportedReasoningEfforts.contains($0) }
        + supportedReasoningEfforts.subtracting(known).sorted()
    } else { self.reasoningOrder = nil }
    self.displayName = displayName
    self.description = description
    self.defaultReasoningEffort = defaultReasoningEffort
    self.priority = priority
    self.showInPicker = showInPicker
    self.contextWindow = contextWindow
  }
}

enum ReasoningCommand {
  case increase, decrease, cycle

  init?(_ id: String) {
    switch id {
    case "reasoning-increase": self = .increase
    case "reasoning-decrease": self = .decrease
    case "reasoning-cycle": self = .cycle
    default: return nil
    }
  }

  private func choices(entry: ModelCatalogEntry?) -> [String] {
    if let supported = entry?.supportedReasoningEfforts {
      let known = Set(AgentReasoningEfforts.available(advanced: Set(AgentAdvancedReasoningEffort.allCases)))
      return (entry?.reasoningOrder ?? []).filter { !$0.isEmpty && known.contains($0) && supported.contains($0) }
    }
    // Codex falls back to these tiers when the model list has no capability record.
    return ["minimal", "low", "medium", "high", "xhigh", "max"]
  }

  func effective(current: String, entry: ModelCatalogEntry?) -> String {
    let selected = current.isEmpty ? entry?.defaultReasoningEffort ?? "medium" : current
    return choices(entry: entry).contains(selected) ? selected : "medium"
  }

  func target(current: String, entry: ModelCatalogEntry?) -> String? {
    let choices = choices(entry: entry)
    guard !choices.isEmpty else { return effective(current: current, entry: entry) }
    let index = choices.firstIndex(of: effective(current: current, entry: entry)) ?? -1
    switch self {
    case .increase: return choices[min(index + 1, choices.count - 1)]
    case .decrease: return choices[max(index - 1, 0)]
    case .cycle: return choices[index == choices.count - 1 ? 0 : index + 1]
    }
  }
}

@MainActor @Observable
final class ModelCatalog {
  private(set) var models: [String] = []
  private(set) var supportedReasoningEfforts: [String: Set<String>] = [:]
  private(set) var details: [String: ModelCatalogEntry] = [:]
  private(set) var loading = false
  private(set) var error: String?
  private(set) var source: ModelCatalogSource?
  @ObservationIgnored private var generation = UUID()

  nonisolated static func decode(_ data: Data) throws -> [String] {
    try decodeDetails(data).map(\.id)
  }

  nonisolated static func decodeDetails(_ data: Data) throws -> [ModelCatalogEntry] {
    do {
      guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rows = (response["data"] ?? response["models"]) as? [[String: Any]] else { throw DecodingError.dataCorrupted(
          .init(codingPath: [], debugDescription: "Missing model data")) }
      var entries: [String: ModelCatalogEntry] = [:]
      for row in rows {
        guard let id = (row["id"] ?? row["slug"]) as? String else { throw DecodingError.dataCorrupted(
          .init(codingPath: [], debugDescription: "Missing model ID")) }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        let value = row["supported_reasoning_efforts"] ?? row["supportedReasoningEfforts"]
          ?? row["supported_reasoning_levels"] ?? row["supportedReasoningLevels"]
        let effortOrder: [String]? = {
          if let strings = value as? [String] { return strings }
          if let objects = value as? [[String: Any]] {
            return objects.compactMap {
              ($0["reasoning_effort"] ?? $0["reasoningEffort"] ?? $0["effort"]) as? String
            }
          }
          return nil
        }()
        let efforts = effortOrder.map(Set.init)
        let previous = entries[id]
        let visibility = row["visibility"] as? String
        entries[id] = ModelCatalogEntry(
          id: id,
          supportedReasoningEfforts: efforts ?? previous?.supportedReasoningEfforts,
          reasoningOrder: effortOrder ?? previous?.reasoningOrder,
          displayName: (row["display_name"] ?? row["displayName"] ?? row["name"]) as? String
            ?? previous?.displayName,
          description: row["description"] as? String ?? previous?.description,
          defaultReasoningEffort: (row["default_reasoning_level"]
            ?? row["default_reasoning_effort"] ?? row["defaultReasoningEffort"]) as? String
            ?? previous?.defaultReasoningEffort,
          priority: row["priority"] as? Int ?? previous?.priority,
          showInPicker: (row["show_in_picker"] ?? row["showInPicker"]) as? Bool
            ?? (visibility.map { $0 == "list" }) ?? previous?.showInPicker,
          contextWindow: positiveInteger(row["context_window"] ?? row["contextWindow"])
            ?? positiveInteger(row["max_context_window"] ?? row["maxContextWindow"])
            ?? previous?.contextWindow)
      }
      return entries.values.sorted {
        if $0.priority != $1.priority { return ($0.priority ?? Int.min) > ($1.priority ?? Int.min) }
        return $0.id < $1.id
      }
    } catch {
      throw AgentFailure(message: "服务返回的模型列表格式无效。仍可手动填写模型 ID。")
    }
  }

  nonisolated private static func positiveInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = Int(exactly: number.doubleValue), integer > 0 else { return nil }
    return integer
  }

  func load(
    config: ModelConfiguration,
    fetch: (ModelConfiguration) async throws -> [ModelCatalogEntry] = { config in
      let key = try ModelKeychain.read(account: config.credentialAccount)
      return try await ModelAPIClient().modelDetails(config: config, key: key)
    }
  ) async {
    let token = UUID()
    generation = token
    models = []
    supportedReasoningEfforts = [:]
    details = [:]
    source = nil
    error = nil
    loading = true
    defer { if generation == token { loading = false } }
    do {
      let result = try await fetch(config)
      guard !Task.isCancelled, generation == token else { return }
      source = ModelCatalogSource(config)
      models = result.filter { $0.showInPicker != false }.map(\.id)
      details = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
      supportedReasoningEfforts = result.reduce(into: [:]) { values, entry in
        if let efforts = entry.supportedReasoningEfforts { values[entry.id] = efforts }
      }
    } catch {
      guard !Task.isCancelled, generation == token else { return }
      self.error = error.localizedDescription
    }
  }

  func choices(current: String, query: String) -> [String] {
    let all = current.isEmpty ? models : [current] + models.filter { $0 != current }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? all : all.filter {
      $0.localizedCaseInsensitiveContains(query)
        || (details[$0]?.displayName?.localizedCaseInsensitiveContains(query) ?? false)
        || (details[$0]?.description?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  func title(for model: String) -> String {
    nonempty(details[model]?.displayName) ?? model
  }

  func subtitle(for model: String) -> String? {
    guard let detail = details[model] else { return nil }
    let description = nonempty(detail.description)
    if title(for: model) == model { return description }
    return ([model] + (description.map { [$0] } ?? [])).joined(separator: " · ")
  }

  func defaultReasoningEffort(for model: String) -> String? {
    details[model]?.defaultReasoningEffort
  }

  private func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }

  func availableReasoning(for model: String, advanced: Set<AgentAdvancedReasoningEffort>) -> [String] {
    let visible = AgentReasoningEfforts.available(advanced: advanced)
    guard let supported = supportedReasoningEfforts[model] else { return visible }
    let allowed = Set(visible)
    return [""] + (details[model]?.reasoningOrder ?? []).filter { allowed.contains($0) && supported.contains($0) }
  }

  func powerChoices(for model: String, advanced: Set<AgentAdvancedReasoningEffort>) -> [String] {
    guard supportedReasoningEfforts[model] != nil else { return [] }
    let choices = availableReasoning(for: model, advanced: advanced).filter { !$0.isEmpty }
    return choices.count >= 2 ? choices : []
  }

  func powerReasoning(for model: String, current: String,
    advanced: Set<AgentAdvancedReasoningEffort>) -> String? {
    let effective = current.isEmpty ? defaultReasoningEffort(for: model) ?? "medium" : current
    return powerChoices(for: model, advanced: advanced).contains(effective) ? effective : nil
  }

  func powerTarget(for model: String, current: String,
    advanced: Set<AgentAdvancedReasoningEffort>, increasing: Bool) -> String? {
    let choices = powerChoices(for: model, advanced: advanced)
    guard let effective = powerReasoning(for: model, current: current, advanced: advanced),
      let index = choices.firstIndex(of: effective) else { return nil }
    return choices[min(max(index + (increasing ? 1 : -1), 0), choices.count - 1)]
  }

  func reasoningWhenSelecting(_ model: String, current: String) -> String {
    guard !current.isEmpty, let supported = supportedReasoningEfforts[model],
      !supported.contains(current) else { return current }
    return ""
  }

  func isCurrentReasoningUnsupported(for model: String, reasoning: String) -> Bool {
    !reasoning.isEmpty && (supportedReasoningEfforts[model].map { !$0.contains(reasoning) } ?? false)
  }
}
