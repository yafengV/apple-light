import Foundation

extension WorkspaceStore {
  func contextWindow(for taskID: String?) -> Int? {
    let config = modelConfiguration(for: taskID)
    return skillModelCatalogs[ModelCatalogSource(config)]?[config.model]?.contextWindow
  }

  func loadContextWindow(for taskID: String?,
    fetch: (ModelConfiguration) async throws -> [ModelCatalogEntry] = { config in
      let key = try ModelKeychain.read(account: config.credentialAccount)
      return try await ModelAPIClient().modelDetails(config: config, key: key, timeout: 3)
    }) async -> Int? {
    let config = modelConfiguration(for: taskID)
    let source = ModelCatalogSource(config)
    if let catalog = skillModelCatalogs[source] {
      return catalog[config.model]?.contextWindow
    }
    let generation = skillModelCatalogGenerations[source] ?? UUID()
    skillModelCatalogGenerations[source] = generation
    do {
      let entries = try await fetch(config)
      guard !Task.isCancelled else { return nil }
      if skillModelCatalogGenerations[source] == generation, skillModelCatalogs[source] == nil {
        skillModelCatalogs[source] = Dictionary(entries.map { ($0.id, $0) },
          uniquingKeysWith: { _, latest in latest })
      }
      return skillModelCatalogs[source]?[config.model]?.contextWindow
    } catch {
      return nil
    }
  }

  func captureSkillModelMetadata(_ catalog: ModelCatalog, config: ModelConfiguration) {
    let source = ModelCatalogSource(config)
    guard !Task.isCancelled, catalog.source == source, !catalog.loading, catalog.error == nil else { return }
    skillModelCatalogGenerations[source] = UUID()
    skillModelCatalogs[source] = catalog.details
  }

  func invalidateSkillModelMetadata(account: String) {
    let sources = Set(skillModelCatalogs.keys).union(skillModelCatalogGenerations.keys)
    for source in sources where source.account == account {
      skillModelCatalogs[source] = nil
      skillModelCatalogGenerations[source] = UUID()
    }
  }

  func skillMetadataBudget(config: ModelConfiguration, key: String?,
    fetch: ((ModelConfiguration, String?) async throws -> [ModelCatalogEntry])? = nil) async throws -> SkillMetadataBudget {
    try Task.checkCancellation()
    if let configured = config.skillMetadataMaxTokens, configured > 0 {
      return .forModel(contextWindow: nil, maxContextTokens: configured)
    }
    let source = ModelCatalogSource(config)
    if let catalog = skillModelCatalogs[source] {
      return .forModel(contextWindow: catalog[config.model]?.contextWindow)
    }
    let generation = skillModelCatalogGenerations[source] ?? UUID()
    skillModelCatalogGenerations[source] = generation
    let entries: [ModelCatalogEntry]
    do {
      if let fetch { entries = try await fetch(config, key) }
      else { entries = try await ModelAPIClient().modelDetails(config: config, key: key, timeout: 3) }
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      // A missing /models endpoint must not prevent a valid conversation.
      entries = []
    }
    try Task.checkCancellation()
    if skillModelCatalogGenerations[source] == generation, skillModelCatalogs[source] == nil {
      skillModelCatalogs[source] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    return .forModel(contextWindow: skillModelCatalogs[source]?[config.model]?.contextWindow)
  }
}
