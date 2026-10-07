import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ModelPowerPickerTests: XCTestCase {
  struct Fixture {
    let store: WorkspaceStore
    let root: URL
    let log: URL
    let window: NSWindow
    let host: NSHostingView<ComposerModelPicker>
  }

  private func fixture(model: String, reasoning: String = "") async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-power-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("requests.jsonl")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_power_server.py")
    let reference = try XCTUnwrap(Bundle.module.url(forResource: "model_power_reference_656",
      withExtension: "json", subdirectory: "Fixtures"))
    process.arguments = ["-u", script.path, reference.path, log.path]
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
    await store.restore()
    addTeardownBlock { await store.shutdown() }
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "global-model"; config.reasoning = "high"
    try store.saveModelConfiguration(config)
    store.library.tasks = [.init(id: "power-task", project: "", title: "Power", runIDs: [])]
    try store.selectModel(model, reasoning: reasoning, taskID: "power-task")
    let host = NSHostingView(rootView: ComposerModelPicker(store: store, taskID: "power-task"))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    addTeardownBlock { @MainActor in window.close() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while store.skillModelCatalogs[ModelCatalogSource(config)] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(store.skillModelCatalogs[ModelCatalogSource(config)])
    try await settle(host)
    return .init(store: store, root: root, log: log, window: window, host: host)
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
  }
  private func find<T: NSView>(_ root: NSView, as type: T.Type) -> [T] {
    (root as? T).map { [$0] } ?? root.subviews.flatMap { find($0, as: type) }
  }

  func testActualPickerMapsDefaultToProviderOrderedStopAndPersistsExplicitChangeOnlyToTask() async throws {
    let f = try await fixture(model: "ordered")
    let slider = try XCTUnwrap(find(f.host, as: NSSlider.self).first)
    XCTAssertEqual(find(f.host, as: NSSlider.self).count, 1)
    XCTAssertEqual(slider.doubleValue, slider.maxValue, "Provider order is high, low; default low is the last stop")
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "")
    slider.sendAction(slider.action, to: slider.target)
    try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "", "No-op must preserve omitted effort")
    slider.doubleValue = slider.minValue
    XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
    try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "high")
    XCTAssertEqual(f.store.modelConfiguration.model, "global-model")
    XCTAssertEqual(f.store.modelConfiguration.reasoning, "high")
    let library = try WorkspaceLibrary.load(from: f.root.appendingPathComponent("Data/workspace.json"))
    XCTAssertEqual(library.tasks.first?.modelSelection?.reasoning, "high")
    XCTAssertFalse(f.window.isVisible)
    let requests = try String(contentsOf: f.log, encoding: .utf8)
    XCTAssertTrue(requests.contains("/v1/models")); XCTAssertFalse(requests.contains("POST"))
  }

  func testActualPickerSingleUnknownAndHiddenDefaultsKeepAdvancedModelList() async throws {
    for (model, reasoning) in [("single", ""), ("empty", ""), ("missing-default", ""),
      ("hidden-default", ""), ("unknown", ""), ("implicit-medium", "unsupported"),
      ("implicit-medium", "ultra")] {
      let f = try await fixture(model: model, reasoning: reasoning)
      XCTAssertTrue(find(f.host, as: NSSlider.self).isEmpty, model)
      XCTAssertFalse(find(f.host, as: NSTextField.self).filter { $0.isEditable }.isEmpty,
        "Model search must remain available: \(model)")
      XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, reasoning)
      XCTAssertFalse(f.window.isVisible)
    }
  }

  func testActualPickerImplicitMediumPositionAndFailedSaveRollback() async throws {
    let f = try await fixture(model: "implicit-medium")
    let slider = try XCTUnwrap(find(f.host, as: NSSlider.self).first)
    XCTAssertEqual(slider.doubleValue, (slider.minValue + slider.maxValue) / 2, accuracy: 0.001)
    let libraryURL = f.root.appendingPathComponent("Data/workspace.json")
    let backup = f.root.appendingPathComponent("workspace-backup.json")
    try FileManager.default.moveItem(at: libraryURL, to: backup)
    try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)
    slider.doubleValue = slider.maxValue; slider.sendAction(slider.action, to: slider.target)
    try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "")
    XCTAssertEqual(slider.doubleValue, (slider.minValue + slider.maxValue) / 2, accuracy: 0.001)
    try FileManager.default.removeItem(at: libraryURL)
    try FileManager.default.moveItem(at: backup, to: libraryURL)
    slider.doubleValue = slider.maxValue; slider.sendAction(slider.action, to: slider.target)
    try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "high")
    XCTAssertFalse(f.window.isVisible)
  }

  func testActualNativeSliderFocusKeyboardClampsCompletesAndRejectsDetachedActions() async throws {
    let f = try await fixture(model: "implicit-medium")
    let slider = try XCTUnwrap(find(f.host, as: ModelPowerSlider.Control.self).first)
    XCTAssertTrue(slider.acceptsFirstResponder)
    XCTAssertTrue(f.window.firstResponder === slider)
    func key(_ code: UInt16) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    for (code, expected): (UInt16, String) in [(123,"low"),(123,"low"),(124,"medium"),
      (124,"high"),(124,"high")] {
      slider.keyDown(with: try key(code)); try await settle(f.host)
      XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, expected)
      XCTAssertTrue(f.window.firstResponder === slider)
    }
    f.store.showingModelPicker = true
    slider.keyDown(with: try key(36)); XCTAssertFalse(f.store.showingModelPicker)
    f.store.libraryLoaded = false
    XCTAssertFalse(slider.accessibilityPerformDecrement())
    f.store.libraryLoaded = true
    slider.removeFromSuperview()
    XCTAssertFalse(slider.accessibilityPerformDecrement())
    XCTAssertEqual(f.store.modelConfiguration(for: "power-task").reasoning, "high")
    XCTAssertFalse(f.window.isVisible)
  }
}
