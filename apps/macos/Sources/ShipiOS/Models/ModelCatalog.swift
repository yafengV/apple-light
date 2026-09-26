import Foundation
import Observation

struct ModelCatalogEntry: Equatable {
  let id: String
  let supportedReasoningEfforts: Set<String>?
  let displayName: String?
  let description: String?
  let defaultReasoningEffort: String?
  let priority: Int?
  let showInPicker: Bool?

  init(id: String, supportedReasoningEfforts: Set<String>? = nil,
    displayName: String? = nil, description: String? = nil,
    defaultReasoningEffort: String? = nil, priority: Int? = nil,
    showInPicker: Bool? = nil) {
    self.id = id
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.displayName = displayName
    self.description = description
    self.defaultReasoningEffort = defaultReasoningEffort
    self.priority = priority
    self.showInPicker = showInPicker
  }
}

@MainActor @Observable
final class ModelCatalog {
  private(set) var models: [String] = []
  private(set) var supportedReasoningEfforts: [String: Set<String>] = [:]
  private(set) var details: [String: ModelCatalogEntry] = [:]
  private(set) var loading = false
  private(set) var error: String?
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
        let efforts: Set<String>? = {
          if let strings = value as? [String] { return Set(strings) }
          if let objects = value as? [[String: Any]] {
            return Set(objects.compactMap {
              ($0["reasoning_effort"] ?? $0["reasoningEffort"] ?? $0["effort"]) as? String
            })
          }
          return nil
        }()
        let previous = entries[id]
        let visibility = row["visibility"] as? String
        entries[id] = ModelCatalogEntry(
          id: id,
          supportedReasoningEfforts: efforts ?? previous?.supportedReasoningEfforts,
          displayName: (row["display_name"] ?? row["displayName"] ?? row["name"]) as? String
            ?? previous?.displayName,
          description: row["description"] as? String ?? previous?.description,
          defaultReasoningEffort: (row["default_reasoning_level"]
            ?? row["default_reasoning_effort"] ?? row["defaultReasoningEffort"]) as? String
            ?? previous?.defaultReasoningEffort,
          priority: row["priority"] as? Int ?? previous?.priority,
          showInPicker: (row["show_in_picker"] ?? row["showInPicker"]) as? Bool
            ?? (visibility.map { $0 == "list" }) ?? previous?.showInPicker)
      }
      return entries.values.sorted {
        if $0.priority != $1.priority { return ($0.priority ?? Int.min) > ($1.priority ?? Int.min) }
        return $0.id < $1.id
      }
    } catch {
      throw AgentFailure(message: "服务返回的模型列表格式无效。仍可手动填写模型 ID。")
    }
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
    error = nil
    loading = true
    defer { if generation == token { loading = false } }
    do {
      let result = try await fetch(config)
      guard !Task.isCancelled, generation == token else { return }
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
    return visible.filter { $0.isEmpty || supported.contains($0) }
  }

  func powerChoices(for model: String, advanced: Set<AgentAdvancedReasoningEffort>) -> [String] {
    guard supportedReasoningEfforts[model] != nil else { return [] }
    let choices = availableReasoning(for: model, advanced: advanced)
    return choices.count >= 2 ? choices : []
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
