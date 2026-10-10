import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ShortcutDictationGroupTests: XCTestCase {
  func testActualShortcutPageInitiallyCollapsesSavedSingleTapInAdvancedGroup() async throws {
    try await withPage { store, _, host, _ in
      let advanced = try self.advanced(host)
      XCTAssertFalse(advanced.expanded)
      XCTAssertEqual(advanced.accessibilityValue() as? String, "已折叠")
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
    }
  }

  func testGroupingAndSearchMatchSevenCurrentReferenceCasesAndModifierExclusion() throws {
    struct Trace: Decodable {
      struct Case: Decodable {
        struct Advanced: Decodable { let expanded: Bool }
        let name: String, ids: [String], query: String, byKeys: Bool, ordinary: [String]
        let searching: Bool, card: Bool, hold: String?, directToggle: String?, advanced: Advanced?
      }
      struct Ignored: Decodable { let key: String, result: String? }
      let cases: [Case], ignoredModifiers: [Ignored]
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "shortcut_dictation_group_reference_688", withExtension: "json", subdirectory: "Fixtures"))
    let trace = try JSONDecoder().decode(Trace.self, from: Data(contentsOf: url))
    XCTAssertEqual(trace.cases.count, 7)
    for item in trace.cases {
      let group = ShortcutDictationGroup(commandIDs: item.ids, query: item.query, searchByKeys: item.byKeys, expanded: false)
      XCTAssertEqual(group.ordinaryCommandIDs, item.ordinary, item.name)
      XCTAssertEqual(group.showsCard, item.card, item.name)
      XCTAssertEqual(group.holdMatches, item.hold != nil, item.name)
      XCTAssertEqual(group.searching, item.searching, item.name)
      XCTAssertEqual(group.showsAdvanced, item.advanced != nil, item.name)
      XCTAssertEqual(group.showsSingleTap, item.directToggle != nil || item.advanced?.expanded == true, item.name)
    }
    XCTAssertEqual(trace.ignoredModifiers.map(\.key), ["Meta", "Control", "Alt", "Shift"])
    XCTAssertTrue(trace.ignoredModifiers.allSatisfy { $0.result == nil })
  }

  func testStateSearchRevealDoesNotOverwriteDisclosureAndUnmountResetsIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = ShortcutPreferences(file: root.appendingPathComponent("keys.json"))
    let state = ShortcutSettingsState()
    XCTAssertTrue(state.dictationGroup(preferences: preferences).showsAdvanced)
    XCTAssertFalse(state.dictationGroup(preferences: preferences).showsSingleTap)
    state.query = "单击听写"
    XCTAssertTrue(state.dictationGroup(preferences: preferences).showsSingleTap)
    XCTAssertFalse(state.dictationGroup(preferences: preferences).showsAdvanced)
    state.query = "听写"; XCTAssertFalse(state.dictationGroup(preferences: preferences).showsSingleTap)
    state.setDictationExpanded(true)
    state.query = "no-such-command"; state.searchChanged(preferences: preferences)
    state.query = "听写"
    XCTAssertFalse(state.dictationGroup(preferences: preferences).showsSingleTap)
    state.setDictationExpanded(true)
    state.begin(ShortcutDictationGroup.toggleID, replacing: nil)
    state.setDictationExpanded(false); XCTAssertNil(state.capture)
    state.setDictationExpanded(true); state.begin(ShortcutDictationGroup.holdID, replacing: nil)
    state.setDictationExpanded(false); XCTAssertNotNil(state.capture, "Only the removed single-tap recorder is cancelled")
    let session = state.searchCaptureID; state.leavePage()
    XCTAssertNil(state.capture); XCTAssertFalse(state.dictationAdvancedExpanded)
    XCTAssertNotEqual(session, state.searchCaptureID)
  }

  func testNumberPreferenceFilteringAndVoiceChatRemainsAnOrdinaryCommand() throws {
    let state = ShortcutSettingsState()
    XCTAssertTrue(state.matchesNumberPreference(.tabs)); state.query = "数字"
    XCTAssertTrue(state.matchesNumberPreference(.sidebar)); state.query = "单击听写"
    XCTAssertFalse(state.matchesNumberPreference(.tabs)); state.toggleSearchMode()
    XCTAssertFalse(state.matchesNumberPreference(.tabs))
    let group = ShortcutDictationGroup(commandIDs: ["realtimeVoice"], query: "语音聊天", searchByKeys: false, expanded: true)
    XCTAssertEqual(group.ordinaryCommandIDs, ["realtimeVoice"]); XCTAssertFalse(group.showsCard)
  }

  func testActualCollapseUnmountsSingleTapRecorderRestoresFocusAndKeepsSavedBinding() async throws {
    try await withPage { store, window, host, editor in
      let advanced = try self.advanced(host)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      XCTAssertTrue(advanced.expanded)
      editor.begin(ShortcutDictationGroup.toggleID, replacing: store.voicePreferences.globalToggleHotkey)
      try await self.settle(host)
      let field = try XCTUnwrap(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      XCTAssertNil(editor.capture); XCTAssertFalse(advanced.expanded)
      XCTAssertTrue(window.firstResponder === advanced)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
      let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(saved.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
    }
  }

  func testActualFilteredSingleTapShowsDirectlyAndReturningToTextDoesNotExpandIt() async throws {
    try await withPage { store, _, host, editor in
      editor.query = "单击听写"; try await self.settle(host)
      XCTAssertTrue(self.descendants(host).compactMap { $0 as? VoiceDictationAdvancedButton.Control }.isEmpty)
      editor.begin(ShortcutDictationGroup.toggleID, replacing: store.voicePreferences.globalToggleHotkey)
      try await self.settle(host)
      XCTAssertEqual(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.count, 1)
      editor.query = "听写"; try await self.settle(host)
      XCTAssertFalse(try self.advanced(host).expanded)
      XCTAssertTrue(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
      XCTAssertNil(editor.capture)
    }
  }

  func testActualKeystrokeSearchIgnoresBareModifierLikeCurrentReference() async throws {
    try await withPage { _, window, host, editor in
      editor.toggleSearchMode(); try await self.settle(host)
      let field = try XCTUnwrap(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      XCTAssertTrue(window.makeFirstResponder(field))
      for flags: NSEvent.ModifierFlags in [.control, []] {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
          timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
        field.flagsChanged(with: event)
      }
      XCTAssertTrue(editor.searchByKeys); XCTAssertTrue(editor.query.isEmpty)
      XCTAssertFalse(editor.dictationAdvancedExpanded)
    }
  }

  func testBindingChangeUnmountsSearchGroupAndResetsDisclosureBeforeItReturns() async throws {
    try await withPage { store, _, host, editor in
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      editor.toggleSearchMode()
      editor.receiveSearch(ShortcutBinding("⌃⌥D"), sessionID: editor.searchCaptureID)
      try await self.settle(host)
      XCTAssertTrue(editor.dictationAdvancedExpanded)
      var preferences = store.voicePreferences; preferences.globalToggleHotkey = nil
      try store.saveVoicePreferences(preferences); try await self.settle(host)
      XCTAssertFalse(editor.dictationGroup(preferences: store.shortcuts).showsCard)
      XCTAssertFalse(editor.dictationAdvancedExpanded)
      preferences.globalToggleHotkey = ShortcutBinding("⌃⌥D")
      try store.saveVoicePreferences(preferences)
      editor.toggleSearchMode(); editor.query = "听写"; try await self.settle(host)
      XCTAssertFalse(try self.advanced(host).expanded)
    }
  }

  func testActualCommandSearchTargetExpandsBeforeScrollAndLeavingPageResetsDisclosure() async throws {
    try await withPage { store, _, host, editor in
      store.settingsSearchRequest = SettingsSearchRequest(result: .init(page: .shortcuts, commandID: ShortcutDictationGroup.toggleID))
      try await self.settle(host)
      XCTAssertTrue(editor.dictationAdvancedExpanded)
      XCTAssertTrue(editor.query.isEmpty)
      editor.query = "听写"; try await self.settle(host)
      XCTAssertTrue(try self.advanced(host).expanded)
      XCTAssertNil(store.settingsSearchRequest)
      let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first)
      XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
      XCTAssertLessThan(try XCTUnwrap(scroll.documentView).bounds.height, host.bounds.height)
      store.settingsPage = .general; try await self.settle(host)
      XCTAssertFalse(editor.dictationAdvancedExpanded)
      store.settingsPage = .shortcuts; try await self.settle(host)
      XCTAssertFalse(try self.advanced(host).expanded)
    }
  }

  func testFilteringKeepsSearchEditorIdentityAndKeyboardFocus() async throws {
    try await withPage { _, window, host, editor in
      let field = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "搜索快捷键…" })
      XCTAssertTrue(window.makeFirstResponder(field))
      let responder = try XCTUnwrap(window.firstResponder)
      for query in ["没有匹配的命令", "", "听写"] {
        editor.query = query; try await self.settle(host)
        XCTAssertTrue(field.window === window)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertTrue(self.descendants(host).contains { $0 === field })
      }
      XCTAssertFalse(try self.advanced(host).expanded)
    }
  }

  func testNativeAdvancedSpaceReleaseIsRequiredAndCancelledOnDeactivation() async throws {
    try await withPage { _, window, host, _ in
      let advanced = try self.advanced(host); XCTAssertTrue(window.makeFirstResponder(advanced))
      func key(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
      }
      advanced.keyDown(with: try key(.keyDown)); XCTAssertFalse(advanced.expanded)
      advanced.keyUp(with: try key(.keyUp)); try await self.settle(host); XCTAssertTrue(advanced.expanded)
      advanced.keyDown(with: try key(.keyDown))
      NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
      advanced.keyUp(with: try key(.keyUp)); try await self.settle(host); XCTAssertTrue(advanced.expanded)
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_SHORTCUT_GROUP_RENDER_PATH"] {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
      }
    }
  }

  private final class Window: NSWindow { override var isKeyWindow: Bool { true } }
  private func withPage(_ body: (WorkspaceStore, NSWindow, NSView, ShortcutSettingsState) async throws -> Void) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    var voice = store.voicePreferences; voice.globalToggleHotkey = ShortcutBinding("⌃⌥D")
    try store.saveVoicePreferences(voice); store.openSettings(.shortcuts)
    let editor = ShortcutSettingsState(); editor.query = "听写"
    let window = Window(contentRect: .init(x: 0, y: 0, width: 760, height: 1000),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: store, editor: editor)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    try await body(store, window, host, editor)
  }
  private func advanced(_ host: NSView) throws -> VoiceDictationAdvancedButton.Control {
    try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictationAdvancedButton.Control }.first)
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded()
  }
}
