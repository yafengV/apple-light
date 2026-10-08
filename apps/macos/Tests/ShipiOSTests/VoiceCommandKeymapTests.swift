import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceCommandKeymapTests: XCTestCase {
  func testCommandRegistryIncludesAllThreeGlobalVoiceCommands() {
    for id in ["globalDictationHold", "globalDictationSingleTap", "realtimeVoice"] {
      XCTAssertNotNil(DesktopCommand.all.first { $0.id == id }, id)
    }
  }

  func testVoicePageBindingMustBlockConflictingGeneralCommand() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let binding = ShortcutBinding("⌃⌥Y")
    store.voicePreferences = VoicePreferences(globalHoldHotkey: binding)
    XCTAssertThrowsError(try store.shortcuts.set(binding, for: "search"))
    XCTAssertNil(store.shortcuts.binding("search"))
    XCTAssertEqual(store.voicePreferences.globalHoldHotkey, binding)
  }

  func testCurrentReferenceScopesAndCaptureCapabilitiesMatchRegistry() throws {
    struct Reference: Decodable {
      struct Command: Decodable { let id: String; let shortcutScope: String; let allowsBareModifiers: Bool }
      let commands: [Command]
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_command_registry_reference_686",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.commands.count, 3)
    for entry in reference.commands {
      let command = try XCTUnwrap(DesktopCommand.all.first { $0.id == entry.id })
      XCTAssertEqual(entry.shortcutScope, "os-global"); XCTAssertTrue(command.isOSGlobal)
      XCTAssertEqual(command.allowsBareModifiers, entry.allowsBareModifiers)
      XCTAssertTrue(command.defaultBindings.isEmpty)
    }
  }

  func testAllGeneralVoiceEditsProjectIntoVoicePreferencesAndOneWorkspaceFile() throws {
    try withStore { store, root in
      for (index, mode) in VoiceShortcutPresentation.Mode.allCases.enumerated() {
        let binding = ShortcutBinding("⌃⌥\(index + 1)")
        try store.shortcuts.set(binding, for: mode.commandID)
        XCTAssertEqual(store.voicePreferences[mode], binding)
        XCTAssertEqual(store.shortcuts.bindings(mode.commandID), [binding])
        XCTAssertEqual(try saved(store)[mode], binding)
        XCTAssertNil(store.shortcuts.overrides[mode.commandID])
        XCTAssertTrue(store.shortcuts.isCustomized(mode.commandID))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("shortcuts.json").path))
      let file = root.appendingPathComponent("workspace.json")
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
      XCTAssertTrue(store.shortcuts.hasCustomizations)
    }
  }

  func testVoiceEditsUpdateGeneralLabelAndKeySearchWithoutReloading() throws {
    try withStore { store, _ in
      var next = store.voicePreferences; next.globalHoldHotkey = ShortcutBinding("⌃")
      try store.saveVoicePreferences(next)
      let command = try XCTUnwrap(DesktopCommand.all.first { $0.id == "globalDictationHold" })
      let editor = ShortcutSettingsState(); editor.toggleSearchMode()
      editor.receiveSearch(ShortcutBinding("⌃"), sessionID: editor.searchCaptureID)
      XCTAssertEqual(store.shortcuts.label(command.id), "⌃")
      XCTAssertTrue(editor.matches(command, preferences: store.shortcuts))
      next.globalHoldHotkey = nil; try store.saveVoicePreferences(next)
      XCTAssertFalse(editor.matches(command, preferences: store.shortcuts))
      XCTAssertFalse(store.shortcuts.hasCustomizations)
    }
  }

  func testGeneralBindingBlocksVoiceModelMutationBeforeSaving() throws {
    try withStore { store, root in
      let binding = ShortcutBinding("⌃⌥Y")
      try store.shortcuts.set(binding, for: "search")
      let file = root.appendingPathComponent("workspace.json"), before = try Data(contentsOf: file)
      var next = store.voicePreferences; next.globalVoiceChatHotkey = binding
      XCTAssertThrowsError(try store.saveVoicePreferences(next))
      XCTAssertNil(store.voicePreferences.globalVoiceChatHotkey)
      XCTAssertEqual(store.shortcuts.binding("search"), binding)
      XCTAssertEqual(try Data(contentsOf: file), before)
      XCTAssertEqual(store.shortcuts.registrationError("realtimeVoice"), store.voiceShortcutRegistrationErrors[.voiceChat])
      XCTAssertTrue(store.shortcuts.registrationError("realtimeVoice")?.contains("搜索任务") == true)
    }
  }

  func testBareModifierOverlapIsRejectedInEitherPageAndDisjointBindingWorks() throws {
    try withStore { store, _ in
      try store.shortcuts.set(ShortcutBinding("⌃"), for: "globalDictationHold")
      XCTAssertThrowsError(try store.shortcuts.set(ShortcutBinding("⌃⌥"), for: "globalDictationSingleTap"))
      var next = store.voicePreferences; next.globalVoiceChatHotkey = ShortcutBinding("⌃⇧")
      XCTAssertThrowsError(try store.saveVoicePreferences(next))
      XCTAssertNil(store.voicePreferences.globalVoiceChatHotkey)
      try store.shortcuts.set(ShortcutBinding("⌥⇧"), for: "globalDictationSingleTap")
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌥⇧"))
      XCTAssertThrowsError(try store.shortcuts.set(ShortcutBinding("⌃"), for: "search"))
    }
  }

  func testGeneralCaptureAllowsModifierReleaseAndRejectsStaleSession() throws {
    try withStore { store, _ in
      let editor = ShortcutSettingsState()
      editor.begin("globalDictationHold", replacing: nil)
      let old = try XCTUnwrap(editor.capture?.id)
      editor.receiveModifier(try flags(.control), sessionID: old, preferences: store.shortcuts)
      XCTAssertNil(store.voicePreferences.globalHoldHotkey)
      editor.receiveModifier(try flags([]), sessionID: old, preferences: store.shortcuts)
      XCTAssertNil(editor.capture)
      XCTAssertEqual(store.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃"))
      editor.begin("globalDictationHold", replacing: ShortcutBinding("⌃"))
      let current = try XCTUnwrap(editor.capture?.id)
      editor.receiveModifier(try flags(.option), sessionID: old, preferences: store.shortcuts)
      editor.receiveModifier(try flags([]), sessionID: old, preferences: store.shortcuts)
      XCTAssertEqual(editor.capture?.id, current)
      XCTAssertEqual(store.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃"))
      editor.cancel(current)
      editor.begin("search", replacing: nil)
      let local = try XCTUnwrap(editor.capture?.id)
      editor.receiveModifier(try flags(.option), sessionID: local, preferences: store.shortcuts)
      editor.receiveModifier(try flags([]), sessionID: local, preferences: store.shortcuts)
      XCTAssertEqual(editor.capture?.id, local); XCTAssertNil(store.shortcuts.binding("search"))
    }
  }

  func testVoiceCommandsCannotAppendAliasesOrReplaceStaleBindings() throws {
    try withStore { store, _ in
      for mode in VoiceShortcutPresentation.Mode.allCases {
        try store.shortcuts.set(ShortcutBinding("⌃⌥Y"), for: mode.commandID)
        XCTAssertThrowsError(try store.shortcuts.replace(nil, with: ShortcutBinding("⌃⌥Z"), for: mode.commandID))
        XCTAssertThrowsError(try store.shortcuts.replace(ShortcutBinding("⌃⌥Z"), with: nil, for: mode.commandID))
        XCTAssertEqual(store.voicePreferences[mode], ShortcutBinding("⌃⌥Y"))
        try store.shortcuts.reset(mode.commandID)
        XCTAssertNil(store.voicePreferences[mode])
      }
    }
  }

  func testRegisteredCombinationConflictThenModifierReleaseMustNotSaveBareBinding() throws {
    try withStore { store, _ in
      let editor = ShortcutSettingsState()
      editor.begin("globalDictationHold", replacing: nil)
      let id = try XCTUnwrap(editor.capture?.id)
      editor.receiveModifier(try flags([.control, .shift]), sessionID: id, preferences: store.shortcuts)
      // Already registered combinations arrive as a binding from Carbon rather
      // than as a local keyDown event. The local dictation command owns this one.
      editor.receive(ShortcutBinding("⌃⇧D"), sessionID: id, preferences: store.shortcuts)
      XCTAssertNotNil(editor.capture?.warning)
      editor.receiveModifier(try flags([]), sessionID: id, preferences: store.shortcuts)
      XCTAssertEqual(editor.capture?.id, id)
      XCTAssertNil(store.voicePreferences.globalHoldHotkey)
      XCTAssertNotNil(editor.capture?.warning)
    }
  }

  func testGeneralSameValueCaptureRemainsNoOpWithoutRetryOrDiskWrite() throws {
    try withStore { store, root in
      let binding = ShortcutBinding("⌃⌥Y")
      try store.shortcuts.set(binding, for: "realtimeVoice")
      let before = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
      var retries = 0; store.voiceHotkeyRegistrationRetryHandler = { _ in retries += 1 }
      store.voiceShortcutRegistrationErrors[.voiceChat] = "未恢复"
      let editor = ShortcutSettingsState(); editor.begin("realtimeVoice", replacing: binding)
      let id = try XCTUnwrap(editor.capture?.id)
      editor.receive(binding, sessionID: id, preferences: store.shortcuts)
      XCTAssertNil(editor.capture); XCTAssertEqual(retries, 0)
      XCTAssertEqual(store.voiceShortcutRegistrationErrors[.voiceChat], "未恢复")
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), before)
    }
  }

  func testResetAllCommitsVoiceAndGeneralBindingsTogetherAndPreservesUnrelatedVoiceFields() throws {
    try withStore { store, _ in
      var voice = VoicePreferences(globalHoldHotkey: ShortcutBinding("⌃⌥Y"),
        dictationDictionary: ["ShipiOS"], realtimeModelID: "custom")
      try store.saveVoicePreferences(voice)
      try store.shortcuts.set(ShortcutBinding("⌃⌥Z"), for: "search")
      try store.shortcuts.setNumberShortcutTarget(.sidebar)
      try store.shortcuts.setExternalBrowserLinkShortcut(.alt)
      try store.shortcuts.resetAll()
      voice.globalHoldHotkey = nil
      XCTAssertEqual(store.voicePreferences, voice); XCTAssertEqual(try saved(store), voice)
      XCTAssertNil(store.shortcuts.binding("search")); XCTAssertFalse(store.shortcuts.hasCustomizations)
      let snapshot = try XCTUnwrap(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json")).shortcutPreferences)
      XCTAssertTrue(snapshot.overrides.isEmpty); XCTAssertEqual(snapshot.primaryNumberShortcutTarget, .sidebar)
      XCTAssertEqual(snapshot.externalBrowserLinkShortcut, .unassigned)
    }
  }

  func testFailedResetOrGeneralVoiceEditPreservesBothSetsOfPreferences() throws {
    try withStore { store, root in
      try store.shortcuts.set(ShortcutBinding("⌃⌥Y"), for: "globalDictationHold")
      try store.shortcuts.set(ShortcutBinding("⌃⌥Z"), for: "search")
      let file = root.appendingPathComponent("workspace.json"), backup = root.appendingPathComponent("backup.json")
      let voice = store.voicePreferences, overrides = store.shortcuts.overrides
      try FileManager.default.moveItem(at: file, to: backup)
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      XCTAssertThrowsError(try store.shortcuts.resetAll())
      XCTAssertEqual(store.voicePreferences, voice); XCTAssertEqual(store.shortcuts.overrides, overrides)
      XCTAssertThrowsError(try store.shortcuts.set(ShortcutBinding("⌃⌥U"), for: "globalDictationHold"))
      XCTAssertEqual(store.voicePreferences, voice); XCTAssertEqual(store.shortcuts.overrides, overrides)
      try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
      XCTAssertEqual(try saved(store), voice)
      try store.shortcuts.resetAll()
      XCTAssertNil(store.voicePreferences.globalHoldHotkey); XCTAssertFalse(store.shortcuts.hasCustomizations)
    }
  }

  func testMigrationReadsLegacyOnceAndReopenedWorkspaceUsesCanonicalSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("shortcuts.json")
    let legacy = ShortcutPreferences(file: file)
    try legacy.set(ShortcutBinding("⌃⌥Y"), for: "search")
    try legacy.setNumberShortcutTarget(.sidebar)
    let original = try Data(contentsOf: file)
    let store = WorkspaceStore(dataRoot: root); await store.restore()
    XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌃⌥Y"))
    try store.shortcuts.set(ShortcutBinding("⌃⌥Z"), for: "realtimeVoice")
    XCTAssertEqual(try Data(contentsOf: file), original)
    try Data("broken legacy file must now be ignored".utf8).write(to: file)
    let reopened = WorkspaceStore(dataRoot: root); await reopened.restore()
    XCTAssertNil(reopened.shortcuts.loadError)
    XCTAssertEqual(reopened.shortcuts.primaryNumberShortcutTarget, .sidebar)
    XCTAssertEqual(reopened.shortcuts.binding("search"), ShortcutBinding("⌃⌥Y"))
    XCTAssertEqual(reopened.shortcuts.binding("realtimeVoice"), ShortcutBinding("⌃⌥Z"))
    try reopened.shortcuts.set(nil, for: "search")
    XCTAssertNil(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).shortcutPreferences?.overrides["realtimeVoice"])
    await reopened.shutdown(); await store.shutdown()
  }

  func testCanonicalReloadFailureKeepsCurrentSnapshotAndRepairIgnoresLegacy() throws {
    try withStore { store, root in
      try store.shortcuts.set(ShortcutBinding("⌃⌥Y"), for: "search")
      let file = root.appendingPathComponent("workspace.json"), original = try Data(contentsOf: file)
      try Data("broken".utf8).write(to: file)
      store.shortcuts.reload(); XCTAssertNotNil(store.shortcuts.loadError)
      XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌃⌥Y"))
      XCTAssertThrowsError(try store.shortcuts.resetAll())
      try original.write(to: file); store.shortcuts.reload()
      XCTAssertNil(store.shortcuts.loadError)
      XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌃⌥Y"))
      XCTAssertEqual(try Data(contentsOf: file), original)
      try FileManager.default.removeItem(at: file)
      store.shortcuts.reload(); XCTAssertNotNil(store.shortcuts.loadError)
      XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌃⌥Y"))
      XCTAssertThrowsError(try store.shortcuts.resetAll())
      try original.write(to: file); store.shortcuts.reload()
      XCTAssertNil(store.shortcuts.loadError)
    }
  }

  func testInvalidLegacyDoesNotGetOverwrittenByVoiceCommandMutation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("shortcuts.json"), data = Data("broken".utf8)
    try data.write(to: file)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    XCTAssertThrowsError(try store.shortcuts.set(ShortcutBinding("⌃⌥Y"), for: "globalDictationHold"))
    XCTAssertNil(store.voicePreferences.globalHoldHotkey)
    XCTAssertEqual(try Data(contentsOf: file), data)
  }

  func testDefaultRestorationAndNumberTargetChangesCannotIntroduceVoiceConflicts() throws {
    try withStore { store, _ in
      try store.shortcuts.set(nil, for: "palette")
      try store.shortcuts.set(ShortcutBinding("⌘K"), for: "globalDictationHold")
      XCTAssertThrowsError(try store.shortcuts.reset("palette"))
      try store.shortcuts.set(nil, for: "focus-chat-1")
      try store.shortcuts.set(ShortcutBinding("⌃1"), for: "realtimeVoice")
      XCTAssertThrowsError(try store.shortcuts.setNumberShortcutTarget(.sidebar))
      XCTAssertEqual(store.shortcuts.primaryNumberShortcutTarget, .tabs)
      XCTAssertNil(store.shortcuts.binding("palette"))
    }
  }

  func testGlobalVoiceEntriesDoNotDispatchAsLocalOrPaletteCommands() throws {
    try withStore { store, _ in
      try store.shortcuts.set(ShortcutBinding("⌃⇧⎋"), for: "realtimeVoice")
      XCTAssertFalse(store.handleModifiedEscape(ShortcutBinding("⌃⇧⎋")))
      XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌃⇧⎋")))
      XCTAssertFalse(store.commandEnabled("realtimeVoice"))
      store.showingCommands = true
      XCTAssertFalse(store.paletteCommandEnabled("realtimeVoice"))
    }
  }

  func testGeneralVoiceMutationUsesRealRegistrationTransactionAndReportsSharedFailure() throws {
    let fixture = try NativeFixture(); defer { fixture.clean() }
    for mode in VoiceShortcutPresentation.Mode.allCases {
      try fixture.store.shortcuts.set(fixture.bindings[0], for: mode.commandID)
      let before = try Data(contentsOf: fixture.file)
      try fixture.blocker.register(fixture.bindings[1])
      XCTAssertThrowsError(try fixture.store.shortcuts.set(fixture.bindings[1], for: mode.commandID))
      XCTAssertEqual(fixture.store.voicePreferences[mode], fixture.bindings[0])
      XCTAssertEqual(try Data(contentsOf: fixture.file), before)
      XCTAssertNotNil(fixture.store.shortcuts.registrationError(mode.commandID))
      XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
      try fixture.blocker.register(nil)
      try fixture.store.shortcuts.set(fixture.bindings[1], for: mode.commandID)
      XCTAssertNil(fixture.store.shortcuts.registrationError(mode.commandID))
      XCTAssertEqual(fixture.store.voicePreferences[mode], fixture.bindings[1])
      XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
      try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
      try fixture.store.shortcuts.reset(mode.commandID)
      try fixture.probe.register(fixture.bindings[1]); try fixture.probe.register(nil)
    }
  }

  func testResetAllDiskFailureKeepsVoiceAndPopoutNativeRegistrationsThenReleasesBoth() throws {
    let fixture = try NativeFixture(); defer { fixture.clean() }
    try fixture.store.shortcuts.set(fixture.bindings[0], for: "globalDictationHold")
    try fixture.store.shortcuts.set(fixture.bindings[1], for: "popout")
    CommandGlobalHotkeyRegistration(pet: AppGlobalHotKey(id: 68_608, title: "宠物") {},
      popout: AppGlobalHotKey(id: 68_609, title: "弹出窗口") {}).connect(to: fixture.store.shortcuts)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
    let saved = try Data(contentsOf: fixture.file), overrides = fixture.store.shortcuts.overrides
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try fixture.store.shortcuts.resetAll())
    XCTAssertEqual(fixture.store.shortcuts.overrides, overrides)
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, fixture.bindings[0])
    for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    try FileManager.default.removeItem(at: fixture.file); try saved.write(to: fixture.file)
    try fixture.store.shortcuts.resetAll()
    XCTAssertNil(fixture.store.voicePreferences.globalHoldHotkey)
    XCTAssertNil(fixture.store.shortcuts.binding("popout"))
    for binding in fixture.bindings.prefix(2) { try fixture.probe.register(binding); try fixture.probe.register(nil) }
  }

  func testActualGeneralVoiceCaptureSavesBareModifierThenVoicePageHasBoundControls() async throws {
    let fixture = try NativeFixture(); defer { fixture.clean() }
    let editor = ShortcutSettingsState(); editor.query = "globalDictationHold"
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: fixture.store, editor: editor))
    window.contentView = host
    editor.begin("globalDictationHold", replacing: nil); try await settle(host)
    let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertEqual(fixture.store.shortcutCaptureCount, 1)
    field.flagsChanged(with: try flags(.control)); field.flagsChanged(with: try flags([]))
    try await settle(host)
    XCTAssertNil(editor.capture); XCTAssertEqual(fixture.store.shortcutCaptureCount, 0)
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃"))
    let voiceHost = NSHostingView(rootView: VoiceSettingsView(store: fixture.store)
      .environment(\.appAppearance, fixture.store.appearance))
    window.contentView = voiceHost; try await settle(voiceHost)
    let clear = try XCTUnwrap(descendants(voiceHost).compactMap { $0 as? VoiceShortcutActionButton.Control }
      .first { $0.accessibilityIdentifier() == "voice-hotkey-clear-hold" })
    XCTAssertEqual(clear.accessibilityLabel(), "清除按住听写快捷键")
    let bitmap = try XCTUnwrap(voiceHost.bitmapImageRepForCachingDisplay(in: voiceHost.bounds))
    voiceHost.cacheDisplay(in: voiceHost.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/shipios-voice-keymap-686.png"))
    XCTAssertFalse(window.isVisible)
  }

  private final class Window: NSWindow { override var isKeyWindow: Bool { true } }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ view: NSView) async throws {
    try await Task.sleep(for: .milliseconds(180)); view.layoutSubtreeIfNeeded()
  }
  @MainActor private final class NativeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var file: URL { root.appendingPathComponent("workspace.json") }
    let store: WorkspaceStore
    let registration: VoiceHotkeyRegistrationController
    let probe = AppGlobalHotKey(id: 68_604, title: "探测") {}
    let blocker = AppGlobalHotKey(id: 68_605, title: "占用") {}
    var bindings: [ShortcutBinding] = []
    init() throws {
      _ = NSApplication.shared
      store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
      registration = VoiceHotkeyRegistrationController(
        hold: AppGlobalHotKey(id: 68_601, title: "按住听写") {},
        toggle: AppGlobalHotKey(id: 68_602, title: "单击听写") {},
        voiceChat: AppGlobalHotKey(id: 68_603, title: "语音聊天") {})
      for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
        let binding = ShortcutBinding("⌘⌃⌥⇧" + digit)
        do { try probe.register(binding); try probe.register(nil); bindings.append(binding) } catch { continue }
        if bindings.count == 3 { break }
      }
      guard bindings.count == 3 else { throw AgentFailure(message: "No three available native test bindings") }
      store.connectVoiceHotkeys(registration) { _ in }
    }
    func clean() {
      store.voiceHotkeyPreferenceCommitHandler = nil; store.globalDictationHotkeyChangeHandler = nil
      store.voiceHotkeyRegistrationRetryHandler = nil
      store.shortcuts.commitGlobalBindings = nil; store.shortcuts.didChange = nil
      store.shortcuts.retryGlobalRegistration = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func withStore(_ body: (WorkspaceStore, URL) throws -> Void) throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    try body(store, root)
  }
  private func saved(_ store: WorkspaceStore) throws -> VoicePreferences {
    try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json")).voicePreferences
  }
  private func flags(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 59))
  }
}
