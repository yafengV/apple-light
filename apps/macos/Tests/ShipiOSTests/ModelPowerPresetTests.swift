import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ModelPowerPresetTests: XCTestCase {
  struct Reference: Decodable {
    struct Case: Decodable {
      struct Model: Decodable { let model: String; let displayName: String; let efforts: [String] }
      let name: String
      let models: [Model]
      let removeXHigh: Bool?
      let expected: [Stop]
    }
    struct Stop: Decodable { let model: String; let reasoningEffort: String; let powerSettingIndex: Int }
    let cases: [Case]
  }
  private func referenceURL() throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "model_power_presets_reference_659",
      withExtension: "json", subdirectory: "Fixtures"))
  }
  func testDefaultPresetCapabilityFilteringAndOrderMatchPublicReference() async throws {
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL()))
    let catalog = ModelCatalog()
    for item in reference.cases {
      await catalog.load(config: ModelConfiguration()) { _ in item.models.map {
        ModelCatalogEntry(id: $0.model, supportedReasoningEfforts: Set($0.efforts),
          reasoningOrder: $0.efforts, displayName: $0.displayName)
      } }
      XCTAssertEqual(catalog.defaultPowerSelections(advanced: [.max, .ultra], removeXHigh: item.removeXHigh ?? false),
        item.expected.map { ModelPowerSelection(model: $0.model, reasoningEffort: $0.reasoningEffort,
          powerSettingIndex: $0.powerSettingIndex) }, item.name)
    }
  }

  func testExplicitModeMissingMetadataHiddenModelsAndAdvancedEffortsDoNotInventPresetStops() async throws {
    let catalog = ModelCatalog()
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "gpt-5.6-terra", supportedReasoningEfforts: ["low"]),
      ModelCatalogEntry(id: "gpt-5.6-sol", supportedReasoningEfforts: ["low", "medium", "high", "ultra"],
        defaultReasoningEffort: "medium"),
    ] }
    XCTAssertEqual(catalog.powerSelections(for: "gpt-5.6-sol", current: "", mode: nil, advanced: []).count, 4)
    XCTAssertEqual(catalog.powerSelections(for: "gpt-5.6-sol", current: "", mode: .model, advanced: []).count, 3)
    XCTAssertEqual(catalog.fallbackPowerSelection(advanced: [])?.id, "gpt-5.6-sol:medium")
    XCTAssertFalse(catalog.defaultPowerSelections(advanced: []).contains { $0.reasoningEffort == "ultra" })
    XCTAssertTrue(catalog.defaultPowerSelections(advanced: [.ultra]).contains { $0.reasoningEffort == "ultra" })
    await catalog.load(config: ModelConfiguration()) { _ in [
      ModelCatalogEntry(id: "gpt-5.6-terra"),
      ModelCatalogEntry(id: "gpt-5.6-sol", supportedReasoningEfforts: ["low", "medium", "high"], showInPicker: false),
    ] }
    XCTAssertTrue(catalog.defaultPowerSelections(advanced: [.ultra]).isEmpty)
    XCTAssertTrue(catalog.powerSelections(for: "gpt-5.6-terra", current: "low", mode: nil, advanced: []).isEmpty)
  }

  func testSelectionModeMigratesPersistsAndFailedWriteDoesNotChangeLiveMode() async throws {
    XCTAssertNil(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).modelPickerSelectionMode)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-mode-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    try store.setModelPickerSelectionMode(.model)
    let file = root.appendingPathComponent("workspace.json")
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).modelPickerSelectionMode, .model)
    let bytes = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.setModelPickerSelectionMode(.default))
    XCTAssertEqual(store.library.modelPickerSelectionMode, .model)
    try FileManager.default.removeItem(at: file); try bytes.write(to: file)
    try store.setModelPickerSelectionMode(.default)
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).modelPickerSelectionMode, .default)
  }

  func testActualPickerChangesModelAndEffortTogetherOnlyForTaskAndRestoresExplicitMode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-preset-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = Process(), output = Pipe(), log = root.appendingPathComponent("requests.jsonl")
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_power_presets_server.py")
    process.arguments = ["-u", script.path, try referenceURL().path, log.path]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    addTeardownBlock {
      if process.isRunning { process.terminate(); process.waitUntilExit() }
      try? FileManager.default.removeItem(at: root)
    }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    addTeardownBlock { await store.shutdown() }
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "global-model"; config.reasoning = "high"
    try store.saveModelConfiguration(config)
    store.library.tasks = [.init(id: "preset-task", project: "", title: "Preset", runIDs: [])]
    try store.selectModel("gpt-5.6-sol", reasoning: "", taskID: "preset-task")
    let host = NSHostingView(rootView: ComposerModelPicker(store: store, taskID: "preset-task"))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    addTeardownBlock { @MainActor in window.close() }
    func descendants<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
      (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type: type) }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while descendants(host, type: NSSlider.self).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let slider = try XCTUnwrap(descendants(host, type: ModelPowerSlider.Control.self).first)
    XCTAssertEqual(slider.numberOfTickMarks, 5)
    XCTAssertEqual(slider.doubleValue, 2)
    XCTAssertEqual(store.modelConfiguration(for: "preset-task").reasoning, "")
    slider.doubleValue = 0; XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(store.modelConfiguration(for: "preset-task").model, "gpt-5.6-terra")
    XCTAssertEqual(store.modelConfiguration(for: "preset-task").reasoning, "low")
    XCTAssertEqual(slider.numberOfTickMarks, 5, "Cross-model selection must keep the shared default preset")
    XCTAssertEqual(store.modelConfiguration, config)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("Data/workspace.json"))
      .tasks.first?.modelSelection?.model, "gpt-5.6-terra")
    try store.setModelPickerSelectionMode(.model)
    try store.selectModel("gpt-5.6-sol", reasoning: "medium", taskID: "preset-task")
    try await Task.sleep(for: .milliseconds(80))
    let explicit = try XCTUnwrap(descendants(host, type: NSSlider.self).first)
    XCTAssertEqual(explicit.numberOfTickMarks, 4)
    XCTAssertEqual(explicit.doubleValue, 1)
    try store.setModelPickerSelectionMode(.default)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(try XCTUnwrap(descendants(host, type: NSSlider.self).first).numberOfTickMarks, 5)
    // Enter the same advanced content with unsupported current capability.
    // Inspect concrete responders; packaged-app routing is verified separately.
    try store.selectModel("global-model", reasoning: "", taskID: "preset-task")
    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    let row = try XCTUnwrap(descendants(host, type: ModelPickerMenuItem.Control.self).first { $0.itemID == "default" })
    XCTAssertTrue(window.firstResponder === row, "Default mode initially focuses the default radio row")
    XCTAssertTrue(descendants(host, type: NSTextField.self).filter { $0.isEditable }.isEmpty)
    let list = try XCTUnwrap(descendants(host, type: NSScrollView.self).first)
    XCTAssertGreaterThan(list.frame.height, 100, "The advanced model list must not collapse inside its host")
    XCTAssertFalse(window.isVisible)
    let requests = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(requests.contains("/v1/models")); XCTAssertFalse(requests.contains("POST"))
  }
}
