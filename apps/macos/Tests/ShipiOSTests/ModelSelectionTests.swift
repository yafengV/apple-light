import XCTest

@testable import ShipiOS

final class ModelSelectionTests: XCTestCase {
  @MainActor func testProtocolChoicePersistsAndLegacyTasksKeepChatCompletions() throws {
    let legacyConfig = try JSONDecoder().decode(ModelConfiguration.self,
      from: Data(#"{"baseURL":"https://example.com/v1","model":"old"}"#.utf8))
    XCTAssertEqual(legacyConfig.apiProtocol, .chatCompletions)
    XCTAssertFalse(legacyConfig.supportsHostedWebSearch)
    var responses = legacyConfig
    responses.apiProtocol = .codexResponses
    responses.supportsHostedWebSearch = true
    let encoded = try JSONEncoder().encode(responses)
    XCTAssertEqual(try JSONDecoder().decode(ModelConfiguration.self, from: encoded).apiProtocol,
      .codexResponses)
    XCTAssertTrue(try JSONDecoder().decode(ModelConfiguration.self, from: encoded).supportsHostedWebSearch)
    let legacyChoice = try JSONDecoder().decode(TaskModelSelection.self,
      from: Data(#"{"model":"old","reasoning":"","providerAccount":"https://example.com/v1"}"#.utf8))
    let store = WorkspaceStore()
    store.modelConfiguration = responses
    store.library.tasks = [WorkspaceTask(id: "old-task", project: "", title: "Old", runIDs: [],
      modelSelection: legacyChoice)]
    XCTAssertEqual(store.modelConfiguration(for: "old-task").apiProtocol, .chatCompletions)
    XCTAssertEqual(store.modelConfiguration(for: nil).apiProtocol, .codexResponses)
  }
  func testCatalogRequiresValidShapeAndKeepsLiteralDistinctIDs() throws {
    let payload = Data(#"{"data":[{"id":"z"},{"id":"Model/A"},{"id":"model/a"},{"id":"z"},{"id":" "}]}"#.utf8)
    XCTAssertEqual(try ModelCatalog.decode(payload), ["Model/A", "model/a", "z"])
    XCTAssertEqual(try ModelCatalog.decode(Data(#"{"data":[]}"#.utf8)), [])
    let detailed = Data(#"{"data":[{"id":"gpt-a","supported_reasoning_efforts":[{"reasoning_effort":"low"},{"reasoning_effort":"max"}]},{"id":"gpt-b","supportedReasoningEfforts":["medium","ultra"]}]}"#.utf8)
    XCTAssertEqual(try ModelCatalog.decodeDetails(detailed), [
      ModelCatalogEntry(id: "gpt-a", supportedReasoningEfforts: ["low", "max"]),
      ModelCatalogEntry(id: "gpt-b", supportedReasoningEfforts: ["medium", "ultra"]),
    ])
    for bad in [#"{"error":{"message":"private-server-detail"}}"#, #"{"data":[{}]}"#, "[]"] {
      XCTAssertThrowsError(try ModelCatalog.decode(Data(bad.utf8))) { error in
        XCTAssertFalse(error.localizedDescription.contains("private-server-detail"))
      }
    }
  }

  @MainActor func testCatalogFailureRetainsConfiguredModelAndAllowsSearch() async {
    let catalog = ModelCatalog()
    await catalog.load(config: ModelConfiguration()) { _ in
      throw AgentFailure(message: "Unavailable")
    }
    XCTAssertEqual(catalog.error, "Unavailable")
    XCTAssertFalse(catalog.loading)
    XCTAssertEqual(catalog.choices(current: "private-model", query: "PRIVATE"), ["private-model"])
    XCTAssertEqual(catalog.choices(current: "private-model", query: "missing"), [])
    await catalog.load(config: ModelConfiguration()) { _ in
      ["a", "private-model", "z"].map { ModelCatalogEntry(id: $0) }
    }
    XCTAssertNil(catalog.error)
    XCTAssertEqual(catalog.choices(current: "private-model", query: ""), ["private-model", "a", "z"])
  }

  @MainActor func testModelReasoningOptionsUseOptionalProviderCapabilities() async {
    let catalog = ModelCatalog()
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "known", supportedReasoningEfforts: ["low", "max"]),
      ModelCatalogEntry(id: "unknown"),
    ] }
    XCTAssertEqual(catalog.availableReasoning(for: "known", advanced: [.max, .ultra]),
      ["", "low", "max"])
    XCTAssertEqual(catalog.availableReasoning(for: "unknown", advanced: [.max]),
      ["", "none", "minimal", "low", "medium", "high", "xhigh", "max"])
    XCTAssertEqual(catalog.availableReasoning(for: "missing", advanced: []),
      AgentReasoningEfforts.standard)
  }

  @MainActor func testOldProviderResponseCannotReplaceNewProviderList() async {
    let catalog = ModelCatalog()
    let started = expectation(description: "first request started")
    var completion: CheckedContinuation<[ModelCatalogEntry], Error>?
    let first = Task {
      await catalog.load(config: ModelConfiguration()) { _ in
        try await withCheckedThrowingContinuation {
          completion = $0
          started.fulfill()
        }
      }
    }
    await fulfillment(of: [started], timeout: 2)
    await catalog.load(config: ModelConfiguration()) { _ in
      [ModelCatalogEntry(id: "new-provider-model", supportedReasoningEfforts: ["low"])]
    }
    completion?.resume(returning: [ModelCatalogEntry(id: "old-provider-model",
      supportedReasoningEfforts: ["ultra"])])
    await first.value
    XCTAssertEqual(catalog.models, ["new-provider-model"])
    XCTAssertEqual(catalog.supportedReasoningEfforts["new-provider-model"], ["low"])
    XCTAssertNil(catalog.supportedReasoningEfforts["old-provider-model"])
    XCTAssertFalse(catalog.loading)
  }

  @MainActor func testCancelledCatalogDoesNotApplyResultsOrLeaveSpinner() async {
    let catalog = ModelCatalog()
    let task = Task {
      await catalog.load(config: ModelConfiguration()) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return [ModelCatalogEntry(id: "cancelled-model")]
      }
    }
    await task.value
    XCTAssertTrue(catalog.models.isEmpty)
    XCTAssertFalse(catalog.loading)
    XCTAssertNil(catalog.error)
  }

  @MainActor func testSelectionPersistsWithoutChangingActiveRequestOrDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    var config = ModelConfiguration()
    config.baseURL = "https://example.com/v1"
    config.model = "old-model"
    config.instructions = "keep these instructions"
    try store.saveModelConfiguration(config)
    let run = AgentRun(
      id: "running", kind: "chat", project: "/fixture", status: "running", createdAt: 0,
      updatedAt: 0, request: .object(["model": .string("old-model")]), result: nil)
    store.runs = [run]
    store.draft = "keep draft"
    try store.selectModel(" new-model ", reasoning: "high")
    XCTAssertEqual(store.draft, "keep draft")
    XCTAssertEqual(store.activeRun?.request["model"].text, "old-model")
    XCTAssertEqual(store.modelConfiguration.baseURL, config.baseURL)
    XCTAssertEqual(store.modelConfiguration.instructions, config.instructions)
    let restored = WorkspaceStore(dataRoot: root)
    await restored.loadModelConfiguration()
    XCTAssertEqual(restored.modelConfiguration.model, "new-model")
    XCTAssertEqual(restored.modelConfiguration.reasoning, "high")
    XCTAssertThrowsError(try store.selectModel(" \n", reasoning: "low"))
    XCTAssertEqual(store.modelConfiguration.model, "new-model")
    XCTAssertEqual(store.modelConfiguration.reasoning, "high")
  }

  @MainActor func testShortcutOpensInlinePickerAndSettingsClosesIt() {
    let store = WorkspaceStore()
    store.executeCommand("model")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .model)
    XCTAssertFalse(store.showingModelPicker)
    store.modelConfiguration.baseURL = "https://example.com/v1"
    store.modelConfiguration.model = "fixture"
    store.action = .build
    store.executeCommand("model")
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.action, .chat)
    XCTAssertTrue(store.showingModelPicker)
    store.openSettings(.model)
    XCTAssertFalse(store.showingModelPicker)
  }

  @MainActor func testTaskChoicePersistsIndependentlyAndProviderChangesDoNotReuseForeignModelIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = "https://example.com/v1"
    config.model = "default-model"
    config.reasoning = "low"
    try store.saveModelConfiguration(config)
    store.library.tasks = [
      .init(id: "one", project: "", title: "One", runIDs: []),
      .init(id: "two", project: "", title: "Two", runIDs: [])]
    store.library.drafts = ["one": "first draft", "two": "second draft"]
    try store.selectModel(" task-model ", reasoning: "high", taskID: "two")
    XCTAssertEqual(store.modelConfiguration, config)
    XCTAssertEqual(store.modelConfiguration(for: "one").model, "default-model")
    XCTAssertEqual(store.modelConfiguration(for: "two").model, "task-model")
    XCTAssertEqual(store.modelConfiguration(for: "two").reasoning, "high")
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.modelConfiguration(for: "two").model, "task-model")
    XCTAssertEqual(restored.library.drafts["one"], "first draft")
    XCTAssertEqual(restored.library.drafts["two"], "second draft")
    config.baseURL = "https://different.example/v1"
    config.model = "different-default"
    try restored.saveModelConfiguration(config)
    XCTAssertEqual(restored.modelConfiguration(for: "two").model, "different-default")
    XCTAssertEqual(restored.modelConfiguration(for: "two").reasoning, "low")
    XCTAssertThrowsError(try restored.selectModel("oops", reasoning: "", taskID: "deleted"))
    XCTAssertEqual(restored.modelConfiguration.model, "different-default")
    await store.shutdown()
    await restored.shutdown()
  }

  @MainActor func testTaskChoiceSaveFailureDoesNotReplacePriorSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration.baseURL = "https://example.com/v1"
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: [])]
    try store.selectModel("before", reasoning: "low", taskID: "task")
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.selectModel("after", reasoning: "high", taskID: "task"))
    XCTAssertEqual(store.modelConfiguration(for: "task").model, "before")
    XCTAssertEqual(store.modelConfiguration(for: "task").reasoning, "low")
    await store.shutdown()
  }

  func testLegacyTaskDecodesWithoutChoiceAndForkKeepsExplicitChoice() throws {
    var library = WorkspaceLibrary()
    var task = try JSONDecoder().decode(WorkspaceTask.self,
      from: Data(#"{"id":"old","project":"","title":"Legacy","runIDs":["run"],"pinned":false,"archived":false}"#.utf8))
    XCTAssertNil(task.modelSelection)
    task.modelSelection = TaskModelSelection(model: "chosen", reasoning: "medium", providerAccount: "provider")
    library.tasks = [task]
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    let fork = try library.forkConversation(taskID: task.id, availableRuns: [run])
    XCTAssertEqual(fork.modelSelection, task.modelSelection)
  }

}
