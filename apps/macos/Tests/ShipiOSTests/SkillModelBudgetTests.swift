import XCTest
@testable import ShipiOS

final class SkillModelBudgetTests: XCTestCase {
  private func config(_ url: String = "https://example.com/v1", model: String = "known",
    api: ModelAPIProtocol = .chatCompletions) -> ModelConfiguration {
    var value = ModelConfiguration()
    value.baseURL = url; value.model = model; value.apiProtocol = api
    return value
  }

  func testBudgetUsesTwoPercentOrCharacterFallbackAndUTF8Approximation() {
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: nil), .characters(8_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: 0), .characters(8_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: -1), .characters(8_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: 100_000), .tokens(2_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: 400_000), .tokens(8_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: 1), .tokens(1))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: 100_000, maxContextTokens: 5_000), .tokens(5_000))
    XCTAssertEqual(SkillMetadataBudget.forModel(contextWindow: nil, maxContextTokens: 50_000), .tokens(10_000))
    XCTAssertGreaterThan(SkillMetadataBudget.forModel(contextWindow: Int.max).limit, 0)
    XCTAssertEqual(SkillMetadataBudget.tokens(1).cost("中文"), 2)
    XCTAssertEqual(SkillMetadataBudget.tokens(1).cost("😀"), 1)
  }

  @MainActor func testIndependentOverrideMigratesValidatesAndAvoidsUnnecessaryDiscovery() async throws {
    let legacy = try JSONDecoder().decode(ModelConfiguration.self, from: Data(#"{"baseURL":"https://example.com/v1","model":"known"}"#.utf8))
    XCTAssertNil(legacy.skillMetadataMaxTokens)
    var overridden = legacy
    overridden.skillMetadataMaxTokens = 50_000
    let encoded = try JSONEncoder().encode(overridden)
    XCTAssertEqual(try JSONDecoder().decode(ModelConfiguration.self, from: encoded).skillMetadataMaxTokens, 50_000)
    let store = WorkspaceStore()
    let budget = try await store.skillMetadataBudget(config: overridden, key: nil) { _, _ in
      XCTFail("An explicit budget does not need a model directory request"); return []
    }
    XCTAssertEqual(budget, .tokens(10_000))
    overridden.skillMetadataMaxTokens = 0
    XCTAssertThrowsError(try overridden.validateEndpoint())
    overridden.skillMetadataMaxTokens = -1
    XCTAssertThrowsError(try overridden.validateEndpoint())
  }

  func testCatalogDecodesAuthoritativeWindowsAndRejectsInvalidNumericMetadata() throws {
    let data = Data(#"{"models":[{"slug":"preferred","context_window":100000,"max_context_window":400000},{"slug":"fallback","maxContextWindow":32000},{"slug":"camel","contextWindow":20000},{"slug":"boolean","context_window":true},{"slug":"fraction","context_window":1.5},{"slug":"zero","context_window":0},{"slug":"string","context_window":"400000"},{"slug":"negative","context_window":-100},{"slug":"huge","context_window":1e100}]}"#.utf8)
    let entries = Dictionary(try ModelCatalog.decodeDetails(data).map { ($0.id, $0) }, uniquingKeysWith: { _, next in next })
    XCTAssertEqual(entries["preferred"]?.contextWindow, 100_000)
    XCTAssertEqual(entries["fallback"]?.contextWindow, 32_000)
    XCTAssertEqual(entries["camel"]?.contextWindow, 20_000)
    for id in ["boolean", "fraction", "zero", "string", "negative", "huge"] {
      XCTAssertNil(entries[id]?.contextWindow)
    }
  }

  func testTokenAllocatorChargesCompleteSerializedMetadataAndKeepsValidUnicode() throws {
    let skills = (0..<12).map { index in
      PluginSkillReference(pluginID: "example", pluginName: "来源", skillID: "skill-\(index)",
        title: "技能 \(index)", fileURL: URL(fileURLWithPath: "/tmp/路径 \"quoted\"/\(index)/SKILL.md"),
        mention: "example/skill-\(index)", summary: String(repeating: "中文😀é \"quoted\"\n", count: 100))
    }
    for limit in [0, 1, 50, 200, 800, 2_000, 8_000] {
      let budget = SkillMetadataBudget.tokens(limit)
      let catalog = SkillDiscoveryContext.make(skills: skills, readTool: true, budget: budget)
      XCTAssertLessThanOrEqual(catalog.metadataCost, limit)
      if limit <= 1 {
        XCTAssertEqual(catalog.metadataCost, 0)
        XCTAssertTrue(catalog.instructions.hasSuffix("\n"), "Do not inject a fragment of the omission marker")
      }
      for line in catalog.instructions.split(separator: "\n") where line.hasPrefix("{") {
        let row = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
        let skill = try XCTUnwrap(skills.first { $0.id == row["id"] })
        XCTAssertEqual(row["path"], skill.fileURL.path)
        XCTAssertTrue(skill.summary.hasPrefix(try XCTUnwrap(row["description"])))
      }
    }
    let roomy = SkillDiscoveryContext.make(skills: skills, readTool: true, budget: .tokens(8_000))
    XCTAssertEqual(roomy.skills.count, skills.count)
    XCTAssertEqual(roomy.omittedCount, 0)
  }

  @MainActor func testMetadataIsCachedByServiceAndProtocolAndSelectedByCurrentModel() async throws {
    let store = WorkspaceStore()
    let a = config(), other = config(model: "other")
    var calls = 0
    let first = try await store.skillMetadataBudget(config: a, key: nil) { _, _ in
      calls += 1
      return [.init(id: "known", contextWindow: 100_000), .init(id: "other", contextWindow: 400_000)]
    }
    XCTAssertEqual(first, .tokens(2_000))
    let second = try await store.skillMetadataBudget(config: other, key: nil) { _, _ in XCTFail("Cached source should be reused"); return [] }
    XCTAssertEqual(second, .tokens(8_000))
    let missing = try await store.skillMetadataBudget(config: config(model: "missing"), key: nil)
    XCTAssertEqual(missing, .characters(8_000))
    let b = try await store.skillMetadataBudget(config: config("https://other.example/v1"), key: nil) { _, _ in
      calls += 1; return [.init(id: "known", contextWindow: 20_000)]
    }
    XCTAssertEqual(b, .tokens(400))
    let core = try await store.skillMetadataBudget(config: config(api: .codexResponses), key: nil) { _, _ in
      calls += 1; return [.init(id: "known", contextWindow: 75_000)]
    }
    XCTAssertEqual(core, .tokens(1_500))
    XCTAssertEqual(calls, 3)
  }

  @MainActor func testUnsupportedCatalogFallsBackAndPickerRefreshCanReplaceIt() async throws {
    let store = WorkspaceStore(), configuration = config()
    let fallback = try await store.skillMetadataBudget(config: configuration, key: nil) { _, _ in
      throw AgentFailure(message: "No models endpoint")
    }
    XCTAssertEqual(fallback, .characters(8_000))
    let again = try await store.skillMetadataBudget(config: configuration, key: nil) { _, _ in XCTFail("Do not retry every turn"); return [] }
    XCTAssertEqual(again, fallback)
    let catalog = ModelCatalog()
    await catalog.load(config: configuration) { _ in [.init(id: "known", contextWindow: 200_000)] }
    store.captureSkillModelMetadata(catalog, config: config("https://wrong.example/v1"))
    XCTAssertNil(store.skillModelCatalogs[ModelCatalogSource(config("https://wrong.example/v1"))])
    store.captureSkillModelMetadata(catalog, config: configuration)
    let updated = try await store.skillMetadataBudget(config: configuration, key: nil)
    XCTAssertEqual(updated, .tokens(4_000))
  }

  @MainActor func testCancellationAndCredentialInvalidationDiscardDelayedMetadata() async throws {
    let store = WorkspaceStore(), configuration = config()
    let catalog = ModelCatalog()
    await catalog.load(config: configuration) { _ in [.init(id: "known", contextWindow: 100_000)] }
    store.captureSkillModelMetadata(catalog, config: configuration)
    for overridden in [false, true] {
      var cached = configuration
      if overridden { cached.skillMetadataMaxTokens = 500 }
      let stopped = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.skillMetadataBudget(config: cached, key: nil)
      }
      do { _ = try await stopped.value; XCTFail("Cancellation must also stop cached and overridden lookups") }
      catch is CancellationError {}
    }
    store.invalidateSkillModelMetadata(account: configuration.credentialAccount)
    let cancelled = Task { () throws -> SkillMetadataBudget in
      try await store.skillMetadataBudget(config: configuration, key: nil) { _, _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return [.init(id: "known", contextWindow: 100_000)]
      }
    }
    do { _ = try await cancelled.value; XCTFail("Cancelled lookup must stop") } catch is CancellationError {}
    XCTAssertNil(store.skillModelCatalogs[ModelCatalogSource(configuration)])
    var completion: CheckedContinuation<[ModelCatalogEntry], Error>?
    let delayed = Task {
      try await store.skillMetadataBudget(config: configuration, key: nil) { _, _ in
        try await withCheckedThrowingContinuation { completion = $0 }
      }
    }
    for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(completion)
    store.invalidateSkillModelMetadata(account: configuration.credentialAccount)
    completion?.resume(returning: [.init(id: "known", contextWindow: 400_000)])
    let ignored = try await delayed.value
    XCTAssertEqual(ignored, .characters(8_000))
    XCTAssertNil(store.skillModelCatalogs[ModelCatalogSource(configuration)])
  }
}
