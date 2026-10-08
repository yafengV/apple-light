import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class VoiceHotkeyRestorationTests: XCTestCase {
  private typealias Mode = VoiceShortcutPresentation.Mode

  func testActualReferenceSubmitsSameValueAndRetriesEachModeAfterFailure() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_shortcut_retry_reference_683",
      withExtension: "json", subdirectory: "Fixtures"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(root["sourceSHA256"] as? String, "dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f")
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.compactMap { $0["mode"] as? String }, ["hold", "toggle", "voiceChat"])
    for item in cases {
      let accelerator = try XCTUnwrap(item["accelerator"] as? String)
      let writes = try XCTUnwrap(item["writes"] as? [[String: Any]])
      XCTAssertEqual(writes.count, 2)
      for write in writes {
        let value = item["mode"] as? String == "voiceChat"
          ? (write["update"] as? [String: Any])?["accelerator"] as? String : write["hotkey"] as? String
        XCTAssertEqual(value, accelerator)
      }
      let pending = try XCTUnwrap(item["pending"] as? [String: Any])
      XCTAssertEqual(pending["capturing"] as? Bool, false); XCTAssertEqual(pending["disabled"] as? Bool, true)
      let failed = try XCTUnwrap(item["failed"] as? [String: Any])
      XCTAssertEqual(failed["accelerator"] as? String, accelerator); XCTAssertNotNil(failed["error"] as? String)
      let restarted = try XCTUnwrap(item["restarted"] as? [String: Any])
      XCTAssertEqual(restarted["capturing"] as? Bool, true); XCTAssertTrue(restarted["error"] is NSNull)
      let repaired = try XCTUnwrap(item["repaired"] as? [String: Any])
      XCTAssertEqual(repaired["accelerator"] as? String, accelerator)
      XCTAssertEqual(repaired["disabled"] as? Bool, false); XCTAssertTrue(repaired["error"] is NSNull)
    }
  }

  func testStartupRegistersAvailableModesAndSelectedRetryKeepsOtherErrors() throws {
    try withFixture { _, _, registration, first, second, probe, bindings in
      let preferences = VoicePreferences(globalHoldHotkey: bindings[0],
        globalToggleHotkey: bindings[1], globalVoiceChatHotkey: bindings[2])
      try first.register(bindings[0]); try second.register(bindings[1])
      let initial = registration.refresh(preferences)
      XCTAssertEqual(initial.attempted, [.hold, .toggle, .voiceChat])
      XCTAssertFalse(initial.holdBindingChanged); XCTAssertEqual(Set(registration.errors.keys), [.hold, .toggle])
      XCTAssertThrowsError(try probe.register(bindings[2]))
      let blocked = registration.refresh(preferences, retrying: .hold)
      XCTAssertEqual(blocked.attempted, [.hold]); XCTAssertFalse(blocked.holdBindingChanged)
      XCTAssertEqual(Set(registration.errors.keys), [.hold, .toggle])
      try first.register(nil)
      let repaired = registration.refresh(preferences, retrying: .hold)
      XCTAssertEqual(repaired.attempted, [.hold]); XCTAssertTrue(repaired.holdBindingChanged)
      XCTAssertEqual(Set(registration.errors.keys), [.toggle])
      let same = registration.refresh(preferences, retrying: .hold)
      XCTAssertFalse(same.holdBindingChanged); XCTAssertEqual(Set(registration.errors.keys), [.toggle])
      let other = registration.refresh(preferences, retrying: .voiceChat)
      XCTAssertEqual(other.attempted, [.voiceChat]); XCTAssertEqual(Set(registration.errors.keys), [.toggle])
      XCTAssertThrowsError(try probe.register(bindings[0]))
    }
  }

  func testEveryRestoredModeRetriesWithoutWritingPreferencesEvenWhenFileIsUnavailable() throws {
    for mode in [Mode.hold, .toggle, .voiceChat] {
      try withFixture { store, root, registration, blocker, _, probe, bindings in
        let preferences = VoicePreferences(globalHoldHotkey: bindings[0],
          globalToggleHotkey: bindings[1], globalVoiceChatHotkey: bindings[2])
        store.voicePreferences = preferences
        let binding = try XCTUnwrap(self.binding(mode, preferences))
        try blocker.register(binding)
        var holdChanges: [Bool] = []
        store.connectVoiceHotkeys(registration) { holdChanges.append($0) }
        XCTAssertEqual(Set(store.voiceShortcutRegistrationErrors.keys), [mode])
        let file = root.appendingPathComponent("workspace.json"), backup = root.appendingPathComponent("saved.json")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        store.retryVoiceHotkeyRegistration(mode)
        XCTAssertNotNil(store.voiceShortcutRegistrationErrors[mode])
        try blocker.register(nil)
        store.retryVoiceHotkeyRegistration(mode)
        XCTAssertTrue(store.voiceShortcutRegistrationErrors.isEmpty)
        XCTAssertEqual(store.voicePreferences, preferences); XCTAssertNil(store.generalSettingsError)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &directory)); XCTAssertTrue(directory.boolValue)
        XCTAssertThrowsError(try probe.register(binding))
        XCTAssertEqual(holdChanges.last, mode == .hold)
      }
    }
  }

  func testConnectedStorePreservesCacheAfterFailedSaveAndNotifiesHoldOnlyAfterSuccess() throws {
    try withFixture { store, root, registration, _, _, probe, bindings in
      let original = VoicePreferences(globalHoldHotkey: bindings[0], globalToggleHotkey: bindings[1])
      store.voicePreferences = original
      var holdChanges: [Bool] = []
      store.connectVoiceHotkeys(registration) { holdChanges.append($0) }
      XCTAssertEqual(holdChanges, [true])
      let file = root.appendingPathComponent("workspace.json"), backup = root.appendingPathComponent("saved.json")
      try FileManager.default.moveItem(at: file, to: backup)
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      var proposed = original; proposed.globalHoldHotkey = bindings[3]
      store.voicePreferences = proposed
      XCTAssertEqual(store.voicePreferences, original); XCTAssertEqual(holdChanges, [true])
      XCTAssertThrowsError(try probe.register(bindings[0]))
      XCTAssertNoThrow(try probe.register(bindings[3])); try probe.register(nil)
      store.retryVoiceHotkeyRegistration(.hold)
      XCTAssertEqual(holdChanges, [true, false]); XCTAssertNil(store.voiceShortcutRegistrationErrors[.hold])
      try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
      store.voicePreferences = proposed
      XCTAssertEqual(store.voicePreferences, proposed); XCTAssertEqual(holdChanges, [true, false, true])
      XCTAssertThrowsError(try probe.register(bindings[3]))
      XCTAssertNoThrow(try probe.register(bindings[0]))
    }
  }

  func testConnectedStoreChangedRowSucceedsWhileAnotherRestoredModeRemainsUnavailable() throws {
    try withFixture { store, _, registration, blocker, _, probe, bindings in
      let original = VoicePreferences(globalHoldHotkey: bindings[0], globalToggleHotkey: bindings[1])
      store.voicePreferences = original; try blocker.register(bindings[0])
      store.connectVoiceHotkeys(registration) { _ in }
      let holdError = try XCTUnwrap(store.voiceShortcutRegistrationErrors[.hold])
      var proposed = original; proposed.globalToggleHotkey = bindings[3]
      store.voicePreferences = proposed
      XCTAssertEqual(store.voicePreferences, proposed)
      XCTAssertEqual(store.voiceShortcutRegistrationErrors[.hold], holdError)
      XCTAssertNil(store.voiceShortcutRegistrationErrors[.toggle])
      XCTAssertThrowsError(try probe.register(bindings[3]))
      XCTAssertNoThrow(try probe.register(bindings[1]))
    }
  }

  private func withFixture(_ action: (WorkspaceStore, URL, VoiceHotkeyRegistrationController,
    AppGlobalHotKey, AppGlobalHotKey, AppGlobalHotKey, [ShortcutBinding]) throws -> Void) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let registration = VoiceHotkeyRegistrationController(
      hold: AppGlobalHotKey(id: 68_320, title: "按住听写") {},
      toggle: AppGlobalHotKey(id: 68_321, title: "单击听写") {},
      voiceChat: AppGlobalHotKey(id: 68_322, title: "语音聊天") {})
    let first = AppGlobalHotKey(id: 68_323, title: "占用一") {}
    let second = AppGlobalHotKey(id: 68_324, title: "占用二") {}
    let probe = AppGlobalHotKey(id: 68_325, title: "探测") {}
    var bindings: [ShortcutBinding] = []
    for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
      let binding = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧" + key))
      do { try probe.register(binding); try probe.register(nil); bindings.append(binding) }
      catch { continue }
      if bindings.count == 4 { break }
    }
    XCTAssertEqual(bindings.count, 4); guard bindings.count == 4 else { return }
    try action(store, root, registration, first, second, probe, bindings)
  }
  private func binding(_ mode: Mode, _ preferences: VoicePreferences) -> ShortcutBinding? {
    switch mode {
    case .hold: return preferences.globalHoldHotkey
    case .toggle: return preferences.globalToggleHotkey
    case .voiceChat: return preferences.globalVoiceChatHotkey
    }
  }
}
