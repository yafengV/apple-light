import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class VoiceHotkeyTransactionTests: XCTestCase {
  private typealias Mode = VoiceShortcutPresentation.Mode

  func testEveryOccupiedModeKeepsMemoryDiskAndOriginalRegistrationThenRetriesSuccessfully() throws {
    for mode in [Mode.hold, .toggle, .voiceChat] {
      try withStore { store, _, transaction, blocker, probe, bindings in
        let original = store.voicePreferences
        try blocker.register(bindings[3])
        var proposed = original; self.set(mode, bindings[3], in: &proposed)
        store.voicePreferences = proposed
        XCTAssertEqual(store.voicePreferences, original)
        XCTAssertEqual(try self.saved(store), original)
        XCTAssertEqual(Set(store.voiceShortcutRegistrationErrors.keys), [mode])
        XCTAssertTrue(store.voiceShortcutRegistrationErrors[mode]?.contains("无法注册") == true)
        for binding in bindings.prefix(3) { XCTAssertThrowsError(try probe.register(binding)) }
        try blocker.register(nil)
        store.voicePreferences = proposed
        XCTAssertEqual(store.voicePreferences, proposed)
        XCTAssertEqual(try self.saved(store), proposed)
        XCTAssertTrue(store.voiceShortcutRegistrationErrors.isEmpty)
        XCTAssertNoThrow(try probe.register(self.binding(mode, original)))
        try probe.register(nil)
        XCTAssertThrowsError(try probe.register(bindings[3]))
        withExtendedLifetime(transaction) {}
      }
    }
  }

  func testLaterModeConflictDiscardsEarlierStagedCandidateAndEntirePreferenceChange() throws {
    try withStore { store, _, _, blocker, probe, bindings in
      let original = store.voicePreferences
      try blocker.register(bindings[4])
      var proposed = original
      proposed.globalHoldHotkey = bindings[3]; proposed.globalToggleHotkey = bindings[4]
      proposed.dictationDictionary = ["不应半保存"]
      store.voicePreferences = proposed
      XCTAssertEqual(store.voicePreferences, original); XCTAssertEqual(try self.saved(store), original)
      XCTAssertEqual(Set(store.voiceShortcutRegistrationErrors.keys), [.toggle])
      XCTAssertNoThrow(try probe.register(bindings[3])); try probe.register(nil)
      for binding in bindings.prefix(3) { XCTAssertThrowsError(try probe.register(binding)) }
    }
  }

  func testDiskFailureDuringReplaceOrClearKeepsOriginalRegistrationsAndAllowsRetry() throws {
    for replacement in [false, true] {
      try withStore { store, root, _, _, probe, bindings in
        let original = store.voicePreferences
        let file = root.appendingPathComponent("workspace.json"), backup = root.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var proposed = original; proposed.globalVoiceChatHotkey = replacement ? bindings[3] : nil
        store.voicePreferences = proposed
        XCTAssertEqual(store.voicePreferences, original)
        XCTAssertNotNil(store.generalSettingsError)
        XCTAssertEqual(Set(store.voiceShortcutRegistrationErrors.keys), [.voiceChat])
        for binding in bindings.prefix(3) { XCTAssertThrowsError(try probe.register(binding)) }
        XCTAssertNoThrow(try probe.register(bindings[3])); try probe.register(nil)
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(try self.saved(store), original)
        store.voicePreferences = proposed
        XCTAssertEqual(store.voicePreferences, proposed); XCTAssertEqual(try self.saved(store), proposed)
        XCTAssertNil(store.generalSettingsError)
        XCTAssertNoThrow(try probe.register(bindings[2]))
      }
    }
  }

  func testUnrelatedVoicePreferenceChangesDoNotAttemptRegistrationOrEraseOtherRowError() throws {
    try withStore { store, _, transaction, _, probe, bindings in
      var attempts = 0
      store.voiceHotkeyPreferenceCommitHandler = { previous, preferences, persist in
        attempts += 1; try transaction.commit(preferences, replacing: previous, persist: persist)
      }
      store.voiceShortcutRegistrationErrors[.hold] = "另一行的错误"
      var proposed = store.voicePreferences
      proposed.dictationLocaleIdentifier = "zh-CN"; proposed.dictationDictionary = ["ShipiOS"]
      store.voicePreferences = proposed
      XCTAssertEqual(attempts, 0); XCTAssertEqual(try self.saved(store), proposed)
      XCTAssertEqual(store.voiceShortcutRegistrationErrors[.hold], "另一行的错误")
      for binding in bindings.prefix(3) { XCTAssertThrowsError(try probe.register(binding)) }
    }
  }

  func testUnchangedUnavailableModeDoesNotBlockAnotherRowsSave() throws {
    try withStore { store, _, transaction, blocker, probe, bindings in
      let original = store.voicePreferences
      // Simulate a restored preference whose native registration is unavailable.
      try transaction.hold.register(nil); try blocker.register(bindings[0])
      store.voiceShortcutRegistrationErrors[.hold] = "原按住组合不可用"
      var proposed = original; proposed.globalToggleHotkey = bindings[3]
      store.voicePreferences = proposed
      XCTAssertEqual(store.voicePreferences, proposed)
      XCTAssertEqual(try self.saved(store), proposed)
      XCTAssertEqual(store.voiceShortcutRegistrationErrors[.hold], "原按住组合不可用")
      XCTAssertNil(store.voiceShortcutRegistrationErrors[.toggle])
      XCTAssertThrowsError(try probe.register(bindings[3]))
      XCTAssertNoThrow(try probe.register(bindings[1]))
    }
  }

  private func withStore(_ action: (WorkspaceStore, URL, VoiceHotkeyRegistrationTransaction,
    AppGlobalHotKey, AppGlobalHotKey, [ShortcutBinding]) throws -> Void) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let transaction = VoiceHotkeyRegistrationTransaction(
      hold: AppGlobalHotKey(id: 68_220, title: "按住听写") {},
      toggle: AppGlobalHotKey(id: 68_221, title: "单击听写") {},
      voiceChat: AppGlobalHotKey(id: 68_222, title: "语音聊天") {})
    let blocker = AppGlobalHotKey(id: 68_223, title: "占用") {}
    let probe = AppGlobalHotKey(id: 68_224, title: "探测") {}
    var bindings: [ShortcutBinding] = []
    for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
      let binding = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧" + key))
      do { try probe.register(binding); try probe.register(nil); bindings.append(binding) }
      catch { continue }
      if bindings.count == 5 { break }
    }
    XCTAssertEqual(bindings.count, 5); guard bindings.count == 5 else { return }
    store.voiceHotkeyPreferenceCommitHandler = { previous, preferences, persist in
      try transaction.commit(preferences, replacing: previous, persist: persist)
    }
    store.voicePreferences = VoicePreferences(globalHoldHotkey: bindings[0],
      globalToggleHotkey: bindings[1], globalVoiceChatHotkey: bindings[2])
    XCTAssertNil(store.generalSettingsError); XCTAssertTrue(store.voiceShortcutRegistrationErrors.isEmpty)
    try action(store, root, transaction, blocker, probe, bindings)
  }
  private func saved(_ store: WorkspaceStore) throws -> VoicePreferences {
    try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json"))).voicePreferences
  }
  private func binding(_ mode: Mode, _ preferences: VoicePreferences) -> ShortcutBinding? {
    switch mode {
    case .hold: return preferences.globalHoldHotkey
    case .toggle: return preferences.globalToggleHotkey
    case .voiceChat: return preferences.globalVoiceChatHotkey
    }
  }
  private func set(_ mode: Mode, _ binding: ShortcutBinding?, in preferences: inout VoicePreferences) {
    switch mode {
    case .hold: preferences.globalHoldHotkey = binding
    case .toggle: preferences.globalToggleHotkey = binding
    case .voiceChat: preferences.globalVoiceChatHotkey = binding
    }
  }
}
