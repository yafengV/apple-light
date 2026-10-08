import XCTest
@testable import ShipiOS

@MainActor final class ModelPowerDefaultTests: XCTestCase {
  func testServiceDefaultModelAndEffortTakePriorityOverHardcodedSolMedium() async throws {
    let entries = try ModelCatalog.decodeDetails(Data(#"{"models":[{"id":"gpt-5.6-terra","supported_reasoning_efforts":["low","medium","high"],"default_reasoning_effort":"low","is_default":true},{"id":"gpt-5.6-sol","supported_reasoning_efforts":["low","medium","high"],"default_reasoning_effort":"medium"}]}"#.utf8))
    let catalog = ModelCatalog()
    await catalog.load(config: ModelConfiguration()) { _ in entries }
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-terra:low")
  }

  struct Reference: Decodable {
    struct Stop: Decodable { let model: String; let reasoningEffort: String; let powerSettingIndex: Int }
    struct Case: Decodable { let name: String; let selections: [Stop]; let preferredID: String?; let expectedID: String? }
    let cases: [Case]
  }
  private func referenceURL() throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "model_power_default_reference_660", withExtension: "json",
      subdirectory: "Fixtures"))
  }
  func testFallbackResolutionMatchesPublicReferenceIncludingSolBoundariesAndColonIDs() throws {
    for item in try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL())).cases {
      let options = item.selections.map { ModelPowerSelection(model: $0.model,
        reasoningEffort: $0.reasoningEffort, powerSettingIndex: $0.powerSettingIndex) }
      XCTAssertEqual(ModelPowerSelection.fallback(in: options, preferredID: item.preferredID)?.id,
        item.expectedID, item.name)
    }
  }
  func testDefaultMetadataAcceptsOnlyBooleansAndMergesExplicitFalse() throws {
    let entries = try ModelCatalog.decodeDetails(Data(#"{"data":[{"id":"snake","is_default":true},{"id":"camel","isDefault":true},{"id":"false","isDefault":false},{"id":"number","isDefault":1},{"id":"string","isDefault":"true"},{"id":"null","isDefault":null},{"id":"duplicate","isDefault":true},{"id":"duplicate","display_name":"Later"},{"id":"overridden","isDefault":true},{"id":"overridden","isDefault":false}]}"#.utf8))
    let defaults = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    XCTAssertEqual(defaults["snake"]?.isDefault, true); XCTAssertEqual(defaults["camel"]?.isDefault, true)
    XCTAssertEqual(defaults["false"]?.isDefault, false)
    for id in ["number", "string", "null"] { XCTAssertNil(defaults[id]?.isDefault) }
    XCTAssertEqual(defaults["duplicate"]?.isDefault, true)
    XCTAssertEqual(defaults["duplicate"]?.displayName, "Later")
    XCTAssertEqual(defaults["overridden"]?.isDefault, false)
  }
  func testUnavailableServiceDefaultUsesSameEffortBeforeMediumAndIgnoresHiddenDefault() async {
    let catalog = ModelCatalog()
    let sol = ModelCatalogEntry(id: "gpt-5.6-sol", supportedReasoningEfforts: ["low", "medium", "high"])
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "gpt-5.6-terra", supportedReasoningEfforts: ["high"],
        defaultReasoningEffort: "high", isDefault: true), sol,
    ] }
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-sol:high")
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "gpt-5.6-terra", supportedReasoningEfforts: ["low", "ultra"],
        defaultReasoningEffort: "ultra", isDefault: true), sol,
    ] }
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-sol:medium")
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "gpt-5.6-terra", supportedReasoningEfforts: ["low"],
        defaultReasoningEffort: "low", showInPicker: false, isDefault: true), sol,
    ] }
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-sol:medium")
    await catalog.load(config: ModelConfiguration()) { _ in throw AgentFailure(message: "Failed") }
    XCTAssertNil(catalog.fallbackPowerSelection(advanced: []))
  }

  func testActualServiceMetadataAndDefaultActionKeepTaskSelectionSeparateFromGlobalConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-default-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = Process(), pipe = Pipe(), log = root.appendingPathComponent("requests.jsonl")
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_power_default_server.py")
    process.arguments = ["-u", script.path, try referenceURL().path, log.path]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    addTeardownBlock {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
      try? FileManager.default.removeItem(at: root)
    }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore(); addTeardownBlock { await store.shutdown() }
    var config = ModelConfiguration(); config.baseURL = "http://127.0.0.1:\(port)/v1"
    config.model = "global-model"; config.reasoning = "high"; config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.library.tasks = [.init(id: "default-task", project: "", title: "Default", runIDs: [])]
    try store.selectModel("gpt-5.6-sol", reasoning: "high", taskID: "default-task")
    try store.setModelPickerSelectionMode(.model)
    let catalog = ModelCatalog(); await catalog.load(config: config)
    XCTAssertNil(catalog.error)
    XCTAssertEqual(catalog.details["gpt-5.6-terra"]?.isDefault, true)
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-terra:low")
    let modelFile = root.appendingPathComponent("Data/model.json"), original = try Data(contentsOf: modelFile)
    try store.selectDefaultPower(from: catalog, taskID: "default-task")
    XCTAssertEqual(store.library.modelPickerSelectionMode, .default)
    XCTAssertEqual(store.modelConfiguration(for: "default-task").model, "gpt-5.6-terra")
    XCTAssertEqual(store.modelConfiguration(for: "default-task").reasoning, "low")
    XCTAssertEqual(store.modelConfiguration(for: "default-task").apiProtocol, .codexResponses)
    XCTAssertEqual(store.modelConfiguration, config)
    XCTAssertEqual(try Data(contentsOf: modelFile), original)
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("Data/workspace.json"))
    XCTAssertEqual(saved.tasks.first?.modelSelection?.model, "gpt-5.6-terra")
    XCTAssertEqual(saved.modelPickerSelectionMode, .default)
    let libraryFile = root.appendingPathComponent("Data/workspace.json")
    try store.setModelPickerSelectionMode(.model)
    let backup = try Data(contentsOf: libraryFile)
    try FileManager.default.removeItem(at: libraryFile)
    try FileManager.default.createDirectory(at: libraryFile, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.selectDefaultPower(from: catalog, taskID: "default-task"))
    XCTAssertEqual(store.library.modelPickerSelectionMode, .model)
    XCTAssertEqual(store.modelConfiguration(for: "default-task").model, "gpt-5.6-terra")
    try FileManager.default.removeItem(at: libraryFile); try backup.write(to: libraryFile)
    let empty = ModelCatalog()
    XCTAssertThrowsError(try store.selectDefaultPower(from: empty, taskID: "default-task"))
    XCTAssertEqual(store.library.modelPickerSelectionMode, .model)
    try store.selectDefaultPower(from: catalog)
    XCTAssertEqual(store.modelConfiguration.model, "gpt-5.6-terra")
    XCTAssertEqual(store.modelConfiguration.reasoning, "low")
    let requests = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(requests.contains("/v1/models")); XCTAssertFalse(requests.contains("POST"))
  }
}
