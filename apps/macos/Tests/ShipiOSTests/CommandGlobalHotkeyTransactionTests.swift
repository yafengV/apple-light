import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CommandGlobalHotkeyTransactionTests: XCTestCase {
  func testOccupiedCandidateMustKeepSavedAndRegisteredPopoutBinding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("keys.json")
    let preferences = ShortcutPreferences(file: file)
    let original = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧7"))
    let candidate = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧8"))
    try preferences.set(nil, for: "pet"); try preferences.set(original, for: "popout")
    let key = AppGlobalHotKey(id: 68_510, title: "弹出窗口") {}
    let blocker = AppGlobalHotKey(id: 68_511, title: "占用") {}
    let probe = AppGlobalHotKey(id: 68_512, title: "探测") {}
    try blocker.register(candidate)
    CommandGlobalHotkeyRegistration(pet: AppGlobalHotKey(id: 68_513, title: "宠物") {},
      popout: key).connect(to: preferences)
    let before = try Data(contentsOf: file)
    XCTAssertThrowsError(try preferences.set(candidate, for: "popout"))
    XCTAssertEqual(preferences.binding("popout"), original)
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertNotNil(preferences.globalRegistrationErrors["popout"])
    XCTAssertThrowsError(try probe.register(original))
  }

  func testSaveFailureKeepsEachOldBindingAndReleasesItsCandidate() throws {
    for id in CommandGlobalHotkeyBindings.commandIDs {
      let fixture = try Fixture(); defer { fixture.clean() }
      try fixture.configure()
      let old = fixture.preferences.binding(id), originalOverrides = fixture.preferences.overrides
      try FileManager.default.removeItem(at: fixture.file)
      try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
      XCTAssertThrowsError(try fixture.preferences.set(fixture.bindings[2], for: id))
      XCTAssertEqual(fixture.preferences.binding(id), old)
      XCTAssertEqual(fixture.preferences.overrides, originalOverrides)
      XCTAssertThrowsError(try fixture.probe.register(old))
      try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
    }
  }

  func testSecondCandidateFailureDoesNotSaveOrCommitTheFirst() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.configure(); try fixture.blocker.register(fixture.bindings[3])
    let previous = CommandGlobalHotkeyBindings(pet: fixture.bindings[0], popout: fixture.bindings[1])
    let next = CommandGlobalHotkeyBindings(pet: fixture.bindings[2], popout: fixture.bindings[3])
    var saves = 0
    XCTAssertThrowsError(try fixture.registration.commit(next, replacing: previous) { saves += 1 }) {
      XCTAssertEqual(($0 as? CommandGlobalHotkeyFailure)?.commandID, "popout")
    }
    XCTAssertEqual(saves, 0)
    for old in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(old)) }
    try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
  }

  func testBatchSaveFailureReleasesBothCandidatesAndKeepsBothOldBindings() throws {
    let fixture = try Fixture(); defer { fixture.clean() }; try fixture.configure()
    let previous = CommandGlobalHotkeyBindings(pet: fixture.bindings[0], popout: fixture.bindings[1])
    let next = CommandGlobalHotkeyBindings(pet: fixture.bindings[2], popout: fixture.bindings[3])
    var saves = 0
    XCTAssertThrowsError(try fixture.registration.commit(next, replacing: previous) {
      saves += 1; throw AgentFailure(message: "test save failure")
    })
    XCTAssertEqual(saves, 1)
    for old in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(old)) }
    for candidate in fixture.bindings.suffix(2) {
      try fixture.probe.register(candidate); try fixture.probe.register(nil)
    }
  }

  func testSuccessfulChangeAndResetReplaceTheNativeAndSavedPopoutBinding() throws {
    let fixture = try Fixture(); defer { fixture.clean() }; try fixture.configure()
    try fixture.preferences.set(fixture.bindings[2], for: "popout")
    XCTAssertEqual(ShortcutPreferences(file: fixture.file).binding("popout"), fixture.bindings[2])
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[2]))
    try fixture.probe.register(fixture.bindings[1]); try fixture.probe.register(nil)
    try fixture.preferences.reset("popout")
    XCTAssertNil(fixture.preferences.binding("popout"))
    XCTAssertNil(ShortcutPreferences(file: fixture.file).binding("popout"))
    try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["popout"])
  }

  func testRestoredUnavailablePetDoesNotBlockPopoutAndReloadRetriesWithoutSaving() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.preferences.set(fixture.bindings[0], for: "pet")
    try fixture.preferences.set(fixture.bindings[1], for: "popout")
    try fixture.blocker.register(fixture.bindings[0]); fixture.registration.connect(to: fixture.preferences)
    XCTAssertNotNil(fixture.preferences.globalRegistrationErrors["pet"])
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["popout"])
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
    let data = try Data(contentsOf: fixture.file)
    fixture.preferences.reload(); XCTAssertNotNil(fixture.preferences.globalRegistrationErrors["pet"])
    try fixture.blocker.register(nil); fixture.preferences.reload()
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["pet"])
    XCTAssertEqual(try Data(contentsOf: fixture.file), data)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
  }

  func testUnchangedUnavailableGlobalCommandDoesNotBlockUnrelatedPreferences() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.preferences.set(fixture.bindings[0], for: "pet")
    try fixture.preferences.set(fixture.bindings[1], for: "popout")
    try fixture.blocker.register(fixture.bindings[0]); fixture.registration.connect(to: fixture.preferences)
    try fixture.preferences.set(fixture.bindings[2], for: "search")
    try fixture.preferences.setNumberShortcutTarget(.sidebar)
    try fixture.preferences.setExternalBrowserLinkShortcut(.primaryShift)
    XCTAssertNotNil(fixture.preferences.globalRegistrationErrors["pet"])
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
    let saved = ShortcutPreferences(file: fixture.file)
    XCTAssertEqual(saved.binding("search"), fixture.bindings[2])
    XCTAssertEqual(saved.primaryNumberShortcutTarget, .sidebar)
    XCTAssertEqual(saved.externalBrowserLinkShortcut, .primaryShift)
  }

  func testResetAllFailedSaveKeepsCustomizationsAndActivePopoutBinding() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    // Keep the pet preference at its default, so resetting it is not a changed
    // candidate even when the running desktop app owns that default shortcut.
    try fixture.preferences.reset("pet")
    try fixture.preferences.set(fixture.bindings[1], for: "popout")
    try fixture.preferences.setExternalBrowserLinkShortcut(.alt)
    fixture.registration.connect(to: fixture.preferences)
    let original = fixture.preferences.overrides
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try fixture.preferences.resetAll())
    XCTAssertEqual(fixture.preferences.overrides, original)
    XCTAssertEqual(fixture.preferences.externalBrowserLinkShortcut, .alt)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
  }

  func testRepairReloadUpdatesNativeBindingAndErrorWithoutRewritingTheFile() throws {
    let fixture = try Fixture(); defer { fixture.clean() }; try fixture.configure()
    let saved = ShortcutPreferences(file: fixture.root.appendingPathComponent("repaired.json"))
    try saved.set(nil, for: "pet"); try saved.set(fixture.bindings[2], for: "popout")
    let repaired = try Data(contentsOf: fixture.root.appendingPathComponent("repaired.json"))
    try repaired.write(to: fixture.file, options: .atomic)
    fixture.preferences.reload()
    XCTAssertEqual(fixture.preferences.binding("popout"), fixture.bindings[2])
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["popout"])
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[2]))
    try fixture.probe.register(fixture.bindings[1]); try fixture.probe.register(nil)
    XCTAssertEqual(try Data(contentsOf: fixture.file), repaired)
  }

  func testDisconnectReleasesControllerAndItsNativeRegistrations() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    weak var connected: CommandGlobalHotkeyRegistration?
    do {
      let registration = CommandGlobalHotkeyRegistration(
        pet: AppGlobalHotKey(id: 68_530, title: "宠物") {},
        popout: AppGlobalHotKey(id: 68_531, title: "弹出窗口") {})
      connected = registration
      try fixture.preferences.set(fixture.bindings[0], for: "popout")
      registration.connect(to: fixture.preferences)
    }
    XCTAssertNotNil(connected); XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
    fixture.preferences.commitGlobalBindings = nil
    fixture.preferences.didChange = nil
    fixture.preferences.retryGlobalRegistration = nil
    XCTAssertNil(connected)
    try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
  }

  func testActualCommandPageCaptureKeepsOldPopoutAfterConflictThenSavesRetry() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }; try fixture.configure()
    try fixture.blocker.register(fixture.bindings[2])
    let store = WorkspaceStore(dataRoot: fixture.root); store.libraryLoaded = true
    store.shortcuts = fixture.preferences
    let editor = ShortcutSettingsState(); editor.query = "popout"
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: store, editor: editor))
    window.contentView = host
    let before = try Data(contentsOf: fixture.file)
    for failure in [true, false] {
      if !failure { try fixture.blocker.register(nil) }
      editor.begin("popout", replacing: fixture.bindings[1]); try await settle(host)
      let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      field.keyDown(with: try input(fixture.bindings[2], window: window)); try await settle(host)
      XCTAssertNil(editor.capture); XCTAssertEqual(store.shortcutCaptureCount, 0)
      if failure {
        XCTAssertNotNil(editor.errors["popout"])
        XCTAssertNotNil(store.popoutHotkeyError)
        XCTAssertEqual(fixture.preferences.binding("popout"), fixture.bindings[1])
        XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
      } else {
        XCTAssertNil(editor.errors["popout"]); XCTAssertNil(store.popoutHotkeyError)
        XCTAssertEqual(fixture.preferences.binding("popout"), fixture.bindings[2])
        XCTAssertEqual(ShortcutPreferences(file: fixture.file).binding("popout"), fixture.bindings[2])
        XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[2]))
      }
    }
    XCTAssertFalse(window.isVisible)
  }

  func testActualCommandPageKeepsSameValueAsNoOpAndReloadRepairsRegistration() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.preferences.set(fixture.bindings[0], for: "pet")
    try fixture.blocker.register(fixture.bindings[0]); fixture.registration.connect(to: fixture.preferences)
    let store = WorkspaceStore(dataRoot: fixture.root); store.libraryLoaded = true
    store.shortcuts = fixture.preferences
    let editor = ShortcutSettingsState(); editor.query = "pet"
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: store, editor: editor)); window.contentView = host
    let before = try Data(contentsOf: fixture.file)
    for failure in [true, false] {
      if !failure { try fixture.blocker.register(nil) }
      editor.begin("pet", replacing: fixture.bindings[0]); try await settle(host)
      let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field))
      field.keyDown(with: try input(fixture.bindings[0], window: window)); try await settle(host)
      XCTAssertNil(editor.capture); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertNil(editor.errors["pet"])
      XCTAssertNotNil(fixture.preferences.globalRegistrationErrors["pet"], "Same value remains a no-op on the general shortcut page")
      XCTAssertEqual(try Data(contentsOf: fixture.file), before)
    }
    fixture.preferences.reload(); try await settle(host)
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["pet"])
    XCTAssertEqual(try Data(contentsOf: fixture.file), before)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
    XCTAssertFalse(window.isVisible)
  }

  func testPopoutSameValueRetryUsesTheDedicatedRegistrationCallbackWithoutSaving() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.preferences.set(fixture.bindings[0], for: "popout")
    try fixture.blocker.register(fixture.bindings[0]); fixture.registration.connect(to: fixture.preferences)
    let before = try Data(contentsOf: fixture.file)
    XCTAssertThrowsError(try fixture.preferences.retryGlobalRegistration?("popout"))
    try fixture.blocker.register(nil); try fixture.preferences.retryGlobalRegistration?("popout")
    XCTAssertNil(fixture.preferences.globalRegistrationErrors["popout"])
    XCTAssertEqual(try Data(contentsOf: fixture.file), before)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
  }

  func testActualReferenceKeepsPopoutRetryDistinctFromGeneralSameValueNoOp() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "command_global_hotkey_reference_685",
      withExtension: "json", subdirectory: "Fixtures"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let reference = try XCTUnwrap(root["generalShortcutReference"] as? [String: Any])
    XCTAssertEqual(reference["version"] as? String, "26.908.70816")
    XCTAssertEqual(reference["capturing"] as? Bool, false); XCTAssertEqual(reference["mutations"] as? Int, 0)
    let current = try XCTUnwrap(root["popoutReference"] as? [String: Any])
    XCTAssertEqual(current["version"] as? String, "26.930.51102")
    let traces = try XCTUnwrap(root["traces"] as? [[String: Any]])
    XCTAssertEqual(traces.count, 3)
    for trace in traces {
      let pending = try XCTUnwrap(trace["pending"] as? [String: Any])
      let failed = try XCTUnwrap(trace["failed"] as? [String: Any])
      let repaired = try XCTUnwrap(trace["repaired"] as? [String: Any])
      XCTAssertEqual(pending["capturing"] as? Bool, false)
      XCTAssertEqual(pending["disabled"] as? Bool, true)
      XCTAssertNotNil(failed["error"] as? String)
      XCTAssertEqual(failed["accelerator"] as? String, "Control+Alt+P")
      XCTAssertTrue(repaired["error"] is NSNull)
      XCTAssertEqual((trace["writes"] as? [[String: Any]])?.count, 2)
    }
  }

  func testActualPopoutRowEndsFailedSameValueCaptureAndRetriesWithoutSaving() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    try fixture.preferences.set(fixture.bindings[0], for: "popout")
    try fixture.blocker.register(fixture.bindings[0]); fixture.registration.connect(to: fixture.preferences)
    let store = WorkspaceStore(dataRoot: fixture.root); store.libraryLoaded = true
    store.shortcuts = fixture.preferences
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 250),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: PopoutHotkeySettingsRow(store: store)); window.contentView = host
    let before = try Data(contentsOf: fixture.file)
    for failure in [true, false] {
      if !failure { try fixture.blocker.register(nil) }
      try await settle(host)
      let edit = try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceShortcutActionButton.Control }
        .first { $0.accessibilityIdentifier() == "popout-hotkey-edit" })
      XCTAssertTrue(edit.accessibilityPerformPress()); try await settle(host)
      XCTAssertNil(store.popoutHotkeyError)
      let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      field.keyDown(with: try input(fixture.bindings[0], window: window)); try await settle(host)
      XCTAssertTrue(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertEqual(store.popoutHotkeyError != nil, failure)
      XCTAssertEqual(fixture.preferences.binding("popout"), fixture.bindings[0])
      XCTAssertEqual(try Data(contentsOf: fixture.file), before)
    }
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
    XCTAssertFalse(window.isVisible)
  }

  func testActualPopoutEditClearCancelAndOldCallbackKeepTheirSeparateLifetimes() async throws {
    let fixture = try Fixture(); defer { fixture.clean() }; try fixture.configure()
    let store = WorkspaceStore(dataRoot: fixture.root); store.libraryLoaded = true
    store.shortcuts = fixture.preferences
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 250),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: PopoutHotkeySettingsRow(store: store)); window.contentView = host
    let control = { (id: String) in
      self.descendants(host).compactMap { $0 as? VoiceShortcutActionButton.Control }
        .first { $0.accessibilityIdentifier() == "popout-hotkey-" + id }
    }
    try await settle(host)
    XCTAssertNotNil(control("clear")); XCTAssertNil(control("cancel"))
    let before = try Data(contentsOf: fixture.file)
    XCTAssertTrue(try XCTUnwrap(control("edit")).accessibilityPerformPress()); try await settle(host)
    let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertNil(control("edit")); XCTAssertNil(control("clear"))
    let cancel = try XCTUnwrap(control("cancel")), stale = try XCTUnwrap(cancel.activate)
    XCTAssertTrue(cancel.accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(store.shortcutCaptureCount, 0)
    XCTAssertTrue(try XCTUnwrap(control("edit")).accessibilityPerformPress()); try await settle(host)
    let replacement = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertTrue(window.makeFirstResponder(replacement)); stale(); try await settle(host)
    XCTAssertTrue(window.firstResponder === replacement); XCTAssertEqual(store.shortcutCaptureCount, 1)
    XCTAssertTrue(try XCTUnwrap(control("cancel")).accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(try Data(contentsOf: fixture.file), before)
    let clear = try XCTUnwrap(control("clear")); XCTAssertTrue(window.makeFirstResponder(clear))
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
      if type == .keyDown {
        clear.keyDown(with: event); XCTAssertEqual(fixture.preferences.binding("popout"), fixture.bindings[1])
      } else { clear.keyUp(with: event) }
    }
    try await settle(host)
    XCTAssertNil(fixture.preferences.binding("popout")); XCTAssertNil(control("clear"))
    XCTAssertNotNil(control("edit")); XCTAssertEqual(store.shortcutCaptureCount, 0)
    XCTAssertEqual(fixture.preferences.binding("pet"), fixture.bindings[0])
    XCTAssertNil(ShortcutPreferences(file: fixture.file).binding("popout"))
    try fixture.probe.register(fixture.bindings[1]); try fixture.probe.register(nil)
    XCTAssertFalse(window.isVisible)
  }

  private final class Window: NSWindow { override var canBecomeKey: Bool { true } }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
  }
  private func input(_ binding: ShortcutBinding, window: NSWindow) throws -> NSEvent {
    let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
      "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
    return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: binding.modifierFlags, timestamp: 1, windowNumber: window.windowNumber,
      context: nil, characters: binding.key, charactersIgnoringModifiers: binding.key,
      isARepeat: false, keyCode: try XCTUnwrap(codes[binding.key])))
  }

  @MainActor private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var file: URL { root.appendingPathComponent("keys.json") }
    let preferences: ShortcutPreferences
    let pet = AppGlobalHotKey(id: 68_520, title: "宠物") {}
    let popout = AppGlobalHotKey(id: 68_521, title: "弹出窗口") {}
    let probe = AppGlobalHotKey(id: 68_522, title: "探测") {}
    let blocker = AppGlobalHotKey(id: 68_523, title: "占用") {}
    let registration: CommandGlobalHotkeyRegistration
    var bindings: [ShortcutBinding] = []
    init() throws {
      preferences = ShortcutPreferences(file: root.appendingPathComponent("keys.json"))
      registration = CommandGlobalHotkeyRegistration(pet: pet, popout: popout)
      try preferences.set(nil, for: "pet")
      for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
        let binding = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧" + digit))
        do { try probe.register(binding); try probe.register(nil); bindings.append(binding) } catch { continue }
        if bindings.count == 4 { break }
      }
      XCTAssertEqual(bindings.count, 4)
      guard bindings.count == 4 else { throw AgentFailure(message: "No four available test bindings") }
    }
    func configure() throws {
      try preferences.set(bindings[0], for: "pet"); try preferences.set(bindings[1], for: "popout")
      registration.connect(to: preferences)
      XCTAssertTrue(preferences.globalRegistrationErrors.isEmpty)
    }
    func clean() {
      preferences.commitGlobalBindings = nil; preferences.didChange = nil; preferences.retryGlobalRegistration = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

}
