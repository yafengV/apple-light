import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ModelPickerMenuTests: XCTestCase {
  struct Fixture {
    let store: WorkspaceStore
    let root: URL
    let host: NSHostingView<ComposerModelPicker>
    let window: NSWindow
  }
  private func fixture(mode: ModelPickerSelectionMode = .model, model: String = "gpt-5.6-sol", reasoning: String = "unsupported") async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-menu-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = root.appendingPathComponent("models.json")
    try Data(#"{"models":[{"id":"gpt-5.6-sol","supported_reasoning_efforts":["low","medium","high"],"default_reasoning_effort":"medium"},{"id":"gpt-5.6-terra","supported_reasoning_efforts":["low","medium","high"],"default_reasoning_effort":"low","isDefault":true}]}"#.utf8).write(to: data)
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_power_default_server.py")
    process.arguments = ["-u", script.path, data.path, root.appendingPathComponent("requests.jsonl").path]
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
    config.model = "global-model"; config.reasoning = "high"
    try store.saveModelConfiguration(config)
    store.library.tasks = [.init(id: "menu-task", project: "", title: "Menu", runIDs: [])]
    try store.selectModel(model, reasoning: reasoning, taskID: "menu-task")
    try store.setModelPickerSelectionMode(mode)
    let host = NSHostingView(rootView: ComposerModelPicker(store: store, taskID: "menu-task"))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 380, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    addTeardownBlock { @MainActor in window.close() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while store.skillModelCatalogs[ModelCatalogSource(config)] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    return .init(store: store, root: root, host: host, window: window)
  }
  private func find<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type: type) }
  }
  func testAdvancedPickerInitialFocusBelongsToSelectedModel() async throws {
    let f = try await fixture()
    let selected = find(f.host, type: NSButton.self).first { $0.accessibilityLabel() == "选择模型：gpt-5.6-sol" }
    XCTAssertNotNil(selected, "Selected model must be an actual keyboard responder")
    if let selected { XCTAssertTrue(f.window.firstResponder === selected) }
    XCTAssertFalse(f.window.isVisible)
  }
  func testMissingCurrentModelUsesFirstAvailableRowWithoutInventingOrReorderingOptions() async throws {
    let f = try await fixture(model: "custom-unlisted")
    let defaults = try row("default", in: f)
    XCTAssertTrue(f.window.firstResponder === defaults)
    let rows = find(f.host, type: ModelPickerMenuItem.Control.self)
    let visualOrder = rows.sorted {
      let a = $0.convert($0.bounds, to: f.host).midY, b = $1.convert($1.bounds, to: f.host).midY
      return f.host.isFlipped ? a < b : a > b
    }
    XCTAssertEqual(visualOrder.map(\.itemID), ["default", "model:gpt-5.6-sol", "model:gpt-5.6-terra"])
    XCTAssertFalse(rows.contains { $0.selected })
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "custom-unlisted")
  }

  private func key(_ code: UInt16, shift: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func row(_ id: String, in f: Fixture) throws -> ModelPickerMenuItem.Control {
    try XCTUnwrap(find(f.host, type: ModelPickerMenuItem.Control.self).first { $0.itemID == id })
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
  }
  func testDefaultRadioFocusAndNativeTabArrowsCycleWithoutChangingSelection() async throws {
    let f = try await fixture(mode: .default)
    let defaults = try row("default", in: f), sol = try row("model:gpt-5.6-sol", in: f)
    let terra = try row("model:gpt-5.6-terra", in: f)
    XCTAssertTrue(f.window.firstResponder === defaults)
    XCTAssertEqual(defaults.accessibilityRole(), .radioButton)
    XCTAssertEqual((defaults.accessibilityValue() as? NSNumber)?.intValue, 1)
    let workspace = f.root.appendingPathComponent("Data/workspace.json")
    let before = try Data(contentsOf: workspace), config = f.store.modelConfiguration
    defaults.keyDown(with: try key(48, shift: true))
    XCTAssertTrue(f.window.firstResponder === terra, "Shift-Tab wraps to last model")
    terra.keyDown(with: try key(125))
    XCTAssertTrue(f.window.firstResponder === defaults, "Down wraps to default")
    defaults.keyDown(with: try key(48)); XCTAssertTrue(f.window.firstResponder === sol)
    sol.keyDown(with: try key(125)); XCTAssertTrue(f.window.firstResponder === terra)
    terra.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === sol)
    sol.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === defaults)
    XCTAssertEqual(try Data(contentsOf: workspace), before, "Walking focus must not select or write")
    XCTAssertEqual(f.store.modelConfiguration, config)
    XCTAssertTrue(find(f.host, type: NSTextField.self).filter { $0.isEditable }.isEmpty)
  }
  func testNativeSpaceSelectsModelReturnsToCompactSliderAndOldRowsCannotAct() async throws {
    let f = try await fixture(), sol = try row("model:gpt-5.6-sol", in: f)
    let terra = try row("model:gpt-5.6-terra", in: f), config = f.store.modelConfiguration
    sol.keyDown(with: try key(125)); XCTAssertTrue(f.window.firstResponder === terra)
    terra.keyDown(with: try key(49)); try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-terra")
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "")
    XCTAssertEqual(f.store.library.modelPickerSelectionMode, .model)
    XCTAssertEqual(f.store.modelConfiguration, config)
    let keyboard = try XCTUnwrap(find(f.host, type: ModelPowerSlider.KeyboardControl.self).first)
    let model = try row("choose-model", in: f)
    XCTAssertEqual((f.window.firstResponder as? ModelPickerMenuItem.Control)?.itemID,
      try referenceFocus("keyboard-return-to-simple"))
    XCTAssertTrue(find(f.host, type: ModelPickerMenuItem.Control.self).allSatisfy { !$0.selected && $0.accessibilityRole() == .menuItem })
    XCTAssertFalse(terra.accessibilityPerformPress(), "Detached rows cannot change a later picker")
    terra.keyDown(with: try key(36))
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-terra")
    let originalFocus = f.store.focusComposer
    model.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === keyboard)
    keyboard.keyDown(with: try key(36)); XCTAssertNotEqual(f.store.focusComposer, originalFocus)
  }
  func testFailedSaveKeepsAdvancedRowsAndCanRetryFromSameResponder() async throws {
    let f = try await fixture(), terra = try row("model:gpt-5.6-terra", in: f)
    let file = f.root.appendingPathComponent("Data/workspace.json"), backup = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertTrue(terra.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-sol")
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "unsupported")
    XCTAssertTrue(terra.acceptsFirstResponder)
    XCTAssertTrue(f.window.firstResponder === terra)
    XCTAssertTrue(find(f.host, type: NSSlider.self).isEmpty)
    try FileManager.default.removeItem(at: file); try backup.write(to: file)
    terra.keyDown(with: try key(36)); try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-terra")
    XCTAssertFalse(find(f.host, type: NSSlider.self).isEmpty)
  }

  struct Reference: Decodable {
    struct Case: Decodable {
      struct Expected: Decodable { let focusedID: String?; let prevented: Bool; let stopped: Bool }
      let name: String; let items: [String]; let currentID: String?; let key: String
      let shift: Bool?; let slider: Bool?; let reasoning: Bool?; let code: String?
      let disabled: [String]?; let noninteractive: [String]?; let hidden: [String]?
      let expected: Expected
    }
    let cases: [Case]
  }
  func testMenuNavigationMatchesNineteenPublicReferenceCases() throws {
    let file = try XCTUnwrap(Bundle.module.url(forResource: "model_menu_navigation_reference_661",
      withExtension: "json", subdirectory: "Fixtures"))
    for item in try JSONDecoder().decode(Reference.self, from: Data(contentsOf: file)).cases {
      let rows = item.items.map { ModelPickerMenuFocus.Item(id: $0,
        disabled: item.disabled?.contains($0) ?? false,
        interactive: !(item.noninteractive?.contains($0) ?? false),
        hidden: item.hidden?.contains($0) ?? false) }
      let result = ModelPickerMenuFocus.destination(items: rows, currentID: item.currentID, key: item.key,
        shift: item.shift ?? false, slider: item.slider ?? false,
        composerReasoningNavigation: item.code == "ComposerNavigation" && item.reasoning == true)
      XCTAssertEqual(result, item.expected.focusedID, item.name)
      XCTAssertEqual(result != nil, item.expected.prevented, item.name)
      XCTAssertEqual(result != nil, item.expected.stopped, item.name)
    }
  }
  func testCompactMenuHasNativeModelActionInThePowerFocusCycle() async throws {
    let f = try await fixture(reasoning: "medium")
    let model = try row("choose-model", in: f), reset = try row("reset-default", in: f)
    let keyboard = try XCTUnwrap(find(f.host, type: ModelPowerSlider.KeyboardControl.self).first)
    XCTAssertTrue(f.window.firstResponder === keyboard)
    XCTAssertEqual(keyboard.accessibilityRole(), .menuItem)
    XCTAssertEqual(model.accessibilityRole(), .menuItem)
    let workspace = f.root.appendingPathComponent("Data/workspace.json")
    let original = try Data(contentsOf: workspace)
    keyboard.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === reset)
    reset.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === model)
    model.keyDown(with: try key(48, shift: true)); XCTAssertTrue(f.window.firstResponder === keyboard)
    keyboard.keyDown(with: try key(125)); XCTAssertTrue(f.window.firstResponder === model)
    model.keyDown(with: try key(48)); XCTAssertTrue(f.window.firstResponder === reset)
    reset.keyDown(with: try key(125)); XCTAssertTrue(f.window.firstResponder === keyboard)
    XCTAssertEqual(try Data(contentsOf: workspace), original)
    keyboard.keyDown(with: try key(124)); try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "high")
    XCTAssertTrue(f.window.firstResponder === keyboard)
    keyboard.keyDown(with: try key(126)); XCTAssertTrue(f.window.firstResponder === reset)
    reset.keyDown(with: try key(49)); try await settle(f.host)
    XCTAssertEqual(f.store.library.modelPickerSelectionMode, .default)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-terra")
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "low")
    XCTAssertEqual((f.window.firstResponder as? ModelPickerMenuItem.Control)?.itemID,
      try referenceFocus("removed-reset-falls-to-first"))
    XCTAssertFalse(reset.accessibilityPerformPress())
    XCTAssertTrue(f.window.firstResponder === model)
    model.keyDown(with: try key(36)); try await settle(f.host)
    XCTAssertTrue(f.window.firstResponder === (try row("default", in: f)))
    XCTAssertFalse(keyboard.acceptsFirstResponder)
    keyboard.keyDown(with: try key(124))
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "low")
  }
  func testPointerSliderExcludesOrdinaryUpDownWhileMenuKeyboardControlNavigates() async throws {
    let f = try await fixture(reasoning: "medium")
    let slider = try XCTUnwrap(find(f.host, type: ModelPowerSlider.Control.self).first)
    XCTAssertTrue(f.window.makeFirstResponder(slider))
    for code: UInt16 in [125, 126] {
      slider.keyDown(with: try key(code))
      XCTAssertTrue(f.window.firstResponder === slider)
      XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "medium")
    }
    slider.keyDown(with: try key(123)); try await settle(f.host)
    XCTAssertTrue(f.window.firstResponder === slider)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, "low")
  }

  func testCompactPowerNativeKeysMatchPublicReferenceForOrdinaryUnlockedEvents() async throws {
    struct Reference: Decodable {
      struct Case: Decodable {
        struct Expected: Decodable { let effects: [[StringOrBool]] }
        let name: String; let current: String; let key: String; let code: String
        let disabled: Bool; let locked: Bool; let expected: Expected
      }
      let cases: [Case]
    }
    let file = try XCTUnwrap(Bundle.module.url(forResource: "model_power_keyboard_reference_662",
      withExtension: "json", subdirectory: "Fixtures"))
    let cases = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: file)).cases
    let codes: [String: UInt16] = ["ArrowLeft":123,"ArrowRight":124,"ArrowUp":126,"ArrowDown":125,"Tab":48," ":49,"Enter":36]
    for item in cases where item.code != "ComposerNavigation" && !item.locked {
      let f = try await fixture(reasoning: item.current)
      let keyboard = try XCTUnwrap(find(f.host, type: ModelPowerSlider.KeyboardControl.self).first)
      f.store.libraryLoaded = true
      try f.store.selectModel("gpt-5.6-sol", reasoning: item.current, taskID: "menu-task")
      try await settle(f.host)
      XCTAssertTrue(f.window.makeFirstResponder(keyboard))
      f.store.showingModelPicker = true
      f.store.libraryLoaded = !item.disabled
      keyboard.keyDown(with: try key(try XCTUnwrap(codes[item.key])))
      f.store.libraryLoaded = true
      try await settle(f.host)
      let selected = item.expected.effects.first { $0.first?.text == "select" }?.dropFirst().first?.text
      let completed = item.expected.effects.contains { $0.first?.text == "complete" }
      XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").reasoning, selected ?? item.current, item.name)
      XCTAssertEqual(f.store.showingModelPicker, !completed, item.name)
    }
  }
  private func referenceFocus(_ name: String) throws -> String {
    struct Reference: Decodable {
      struct Case: Decodable {
        struct Expected: Decodable { let focusedID: String? }
        let name: String; let expected: Expected
      }
      let cases: [Case]
    }
    let file = try XCTUnwrap(Bundle.module.url(forResource: "model_menu_focus_reference_662",
      withExtension: "json", subdirectory: "Fixtures"))
    let cases = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: file)).cases
    return try XCTUnwrap(cases.first { $0.name == name }?.expected.focusedID)
  }
  private enum StringOrBool: Decodable {
    case text(String), flag(Bool)
    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer()
      if let text = try? value.decode(String.self) { self = .text(text) }
      else { self = .flag(try value.decode(Bool.self)) }
    }
    var text: String? { if case .text(let text) = self { return text }; return nil }
  }
  func testFailedCompactResetKeepsFocusedActionAndRetriesWithoutClosing() async throws {
    let f = try await fixture(reasoning: "medium"), reset = try row("reset-default", in: f)
    let file = f.root.appendingPathComponent("Data/workspace.json"), backup = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertTrue(reset.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertTrue(f.window.firstResponder === reset)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-sol")
    XCTAssertEqual(f.store.library.modelPickerSelectionMode, .model)
    try FileManager.default.removeItem(at: file); try backup.write(to: file)
    reset.keyDown(with: try key(36)); try await settle(f.host)
    XCTAssertEqual(f.store.modelConfiguration(for: "menu-task").model, "gpt-5.6-terra")
    XCTAssertEqual((f.window.firstResponder as? ModelPickerMenuItem.Control)?.itemID,
      try referenceFocus("removed-reset-falls-to-first"))
    XCTAssertFalse(reset.accessibilityPerformPress())
  }

  func testNativeCycleSkipsDisabledHiddenAndDetachedRows() throws {
    let navigation = ModelPickerMenuFocus(), content = NSView(frame: .init(x: 0, y: 0, width: 300, height: 250))
    let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = content
    defer { navigation.deactivate(); window.close() }
    let rows = ["a", "b", "c", "d"].enumerated().map { index, id in
      let button = ModelPickerMenuItem.Control(frame: .init(x: 0, y: index * 40, width: 280, height: 34))
      button.itemID = id; button.navigation = navigation; button.canAct = { true }
      content.addSubview(button); navigation.register(button); return button
    }
    navigation.configure(ids: rows.map(\.itemID), preferredID: "a", active: true)
    XCTAssertTrue(window.makeFirstResponder(rows[0]))
    rows[1].isEnabled = false; rows[2].isHidden = true
    rows[0].keyDown(with: try key(125)); XCTAssertTrue(window.firstResponder === rows[3])
    rows[3].removeFromSuperview()
    XCTAssertTrue(window.makeFirstResponder(rows[0]))
    rows[0].keyDown(with: try key(48)); XCTAssertTrue(window.firstResponder === rows[0])
    XCTAssertFalse(rows[3].accessibilityPerformPress())
  }
  func testPendingInitialFocusCannotStealFocusAfterMenuDeactivation() async throws {
    let navigation = ModelPickerMenuFocus(), button = ModelPickerMenuItem.Control()
    let content = NSView(frame: .init(x: 0, y: 0, width: 300, height: 200))
    let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = content
    defer { window.close() }
    button.itemID = "old"; button.navigation = navigation; button.canAct = { true }
    content.addSubview(button); navigation.register(button)
    navigation.configure(ids: ["old"], preferredID: "old", active: true)
    navigation.deactivate()
    let field = NSTextField(frame: .init(x: 10, y: 50, width: 200, height: 24))
    content.addSubview(field); XCTAssertTrue(window.makeFirstResponder(field))
    let responder = window.firstResponder
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertTrue(window.firstResponder === responder)
    XCTAssertFalse(button.accessibilityPerformPress())
    XCTAssertFalse(window.isVisible)
  }
}
