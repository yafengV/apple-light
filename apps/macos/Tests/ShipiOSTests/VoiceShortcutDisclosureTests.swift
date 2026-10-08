import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceShortcutDisclosureTests: XCTestCase {
  func testActualVoicePageOffersCollapsedAdvancedControlEvenWithSavedSingleTapShortcut() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥D")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 1800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VoiceSettingsView(store: store)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host; defer { window.close() }
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }
      .first { $0.accessibilityLabel() == "高级听写快捷键" })
    XCTAssertEqual(button.accessibilityValue() as? String, "已折叠")
    XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func testActualReferenceDisclosureAndCaptureTrace() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_shortcut_disclosure_reference_679", withExtension: "json", subdirectory: "Fixtures"))
    let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    for (key, expanded) in [("collapsed", false), ("expanded", true), ("recollapsed", false)] {
      let state = try XCTUnwrap(trace[key] as? [String: Any])
      XCTAssertEqual(state["expanded"] as? Bool, expanded)
      XCTAssertEqual(state["ariaExpanded"] as? Bool, expanded)
      XCTAssertEqual(state["capture"] as? String, "Control")
    }
    let toggle = try XCTUnwrap(trace["singleTap"] as? [String: Any])
    XCTAssertEqual(toggle["label"] as? String, "Single-tap shortcut")
    XCTAssertTrue(toggle["advanced"] is NSNull)
    XCTAssertEqual(trace["capturing"] as? Bool, true)
    XCTAssertEqual(trace["cancelled"] as? Bool, false)
    let writes = try XCTUnwrap(trace["writes"] as? [[String: Any]])
    XCTAssertEqual(writes.map { $0["name"] as? String }, Array(repeating: "global-dictation-set-toggle-hotkey", count: 2))
    XCTAssertEqual(writes[0]["hotkey"] as? String, "Control+Alt+Shift+K")
    XCTAssertTrue(writes[1]["hotkey"] is NSNull)
  }

  func testActualAdvancedSpaceReleaseThenTabCaptureSavesAndCollapsePreservesBinding() async throws {
    try await withPage { store, window, host in
      let advanced = try self.advanced(host)
      XCTAssertTrue(window.makeFirstResponder(advanced))
      try self.key(.keyDown, 49, " ", window); try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
      try self.key(.keyUp, 49, " ", window); try await self.settle(host)
      XCTAssertTrue(advanced.expanded)
      let capture = try await self.startSingleTapCapture(window, host)
      if !window.isKeyWindow { XCTAssertTrue(window.makeFirstResponder(capture)) }
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
      let saved = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")))
      XCTAssertEqual(saved.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      let secondCapture = try await self.startSingleTapCapture(window, host)
      if !window.isKeyWindow { XCTAssertTrue(window.makeFirstResponder(secondCapture)) }
      try self.key(.keyDown, 53, "\u{1b}", window); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testCollapsingDuringActualCaptureUnmountsItAndReturnsFocusWithoutChangingBinding() async throws {
    try await withPage { store, window, host in
      let advanced = try self.advanced(host)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(capture)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
      XCTAssertTrue(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(window.firstResponder === advanced)
      XCTAssertNil(store.voicePreferences.globalToggleHotkey)
      XCTAssertFalse(store.voiceChatPresented); XCTAssertNil(store.dictation.target)
    }
  }

  func testSearchRevealsCollapsedSingleTapRowAndRetainsDictionaryEditorDuringResize() async throws {
    try await withPage { store, window, host in
      let advanced = try self.advanced(host)
      store.voicePreferences.dictationDictionary = ["Before"]; try await self.settle(host)
      let field = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Jane Doe" })
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.string = "中文未提交词条"
      field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
      editor.setSelectedRange(.init(location: 2, length: 3))
      let request = SettingsSearchRequest(result: .init(page: .voice, field: .voiceToggleHotkey))
      host.rootView = VoiceShortcutTestPage(store: store, request: request)
      window.setContentSize(.init(width: 400, height: 1800)); try await self.settle(host)
      XCTAssertTrue(advanced.expanded)
      XCTAssertTrue(self.descendants(host).contains { $0 === advanced })
      XCTAssertTrue(field.currentEditor() === editor); XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.string, "中文未提交词条"); XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 3))
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Before"])
      XCTAssertEqual(SettingsSearch.results(for: "切换听写快捷键").map(\.field), [.voiceToggleHotkey])
      XCTAssertEqual(SettingsSearch.results(for: "单击听写快捷键").map(\.field), [.voiceToggleHotkey])
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_VOICE_ADVANCED_RENDER_PATH"] {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
      }
    }
  }

  func testNativeDisclosureCancelsPendingSpaceWhenWindowDeactivatesAndSupportsStandardPress() async throws {
    try await withPage { _, window, host in
      let advanced = try self.advanced(host); XCTAssertTrue(window.makeFirstResponder(advanced))
      try self.key(.keyDown, 49, " ", window)
      NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
      try self.key(.keyUp, 49, " ", window); try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
      advanced.performClick(nil); try await self.settle(host); XCTAssertTrue(advanced.expanded)
      try self.key(.keyDown, 49, " ", window)
      XCTAssertTrue(window.makeFirstResponder(nil))
      try self.key(.keyUp, 49, " ", window); try await self.settle(host)
      XCTAssertTrue(advanced.expanded)
    }
  }

  func testLeavingVoicePageResetsDisclosureAndCancelsCaptureWithoutClearingSavedBinding() async throws {
    try await withPage { store, window, host in
      store.settingsPage = .voice; store.destination = .settings
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥D")
      try await self.settle(host)
      let advanced = try self.advanced(host)
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(capture)); XCTAssertEqual(store.shortcutCaptureCount, 1)
      store.settingsPage = .general; try await self.settle(host)
      XCTAssertFalse(advanced.expanded); XCTAssertEqual(store.shortcutCaptureCount, 0)
      store.settingsPage = .voice; try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥D"))
      XCTAssertTrue(advanced.accessibilityPerformPress()); try await self.settle(host)
      store.destination = .workspace; try await self.settle(host)
      XCTAssertFalse(advanced.expanded)
    }
  }

  func testConflictingCaptureExitsWithoutChangingSavedShortcutOrRegisteringAgain() async throws {
    try await withPage { store, window, host in
      store.voicePreferences.globalHoldHotkey = ShortcutBinding("⌃⌥⇧K")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      var registrations = 0; store.globalDictationHotkeyChangeHandler = { registrations += 1 }
      try await self.settle(host)
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(capture))
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(self.descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      XCTAssertEqual(registrations, 0)
    }
  }

  func testSecondEventBeforeRecorderUnmountCannotOverwriteBindingAfterConflict() async throws {
    try await withPage { store, window, host in
      store.voicePreferences.globalHoldHotkey = ShortcutBinding("⌃⌥⇧K")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      try await self.settle(host)
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(capture))
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift])
      try self.key(.keyDown, 37, "l", window, [.control, .option, .shift])
      try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testActualDeferredReferenceFailuresEndCaptureBeforeResultAndKeepErrorsLocal() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_shortcut_failures_reference_680", withExtension: "json", subdirectory: "Fixtures"))
    let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try XCTUnwrap(trace["cases"] as? [[String: Any]]); XCTAssertEqual(cases.count, 6)
    for item in cases {
      let pending = try XCTUnwrap(item["pending"] as? [String: Any])
      let settled = try XCTUnwrap(item["settled"] as? [String: Any])
      let restarted = try XCTUnwrap(item["restarted"] as? [String: Any])
      XCTAssertEqual(pending["capturing"] as? Bool, false); XCTAssertEqual(pending["disabled"] as? Bool, true)
      XCTAssertTrue(pending["error"] is NSNull)
      XCTAssertEqual(settled["capturing"] as? Bool, false); XCTAssertEqual(settled["disabled"] as? Bool, false)
      XCTAssertFalse(try XCTUnwrap(settled["error"] as? String).isEmpty)
      XCTAssertEqual(restarted["capturing"] as? Bool, true); XCTAssertTrue(restarted["error"] is NSNull)
    }
    let conflict = try XCTUnwrap(cases[0]["settled"] as? [String: Any])
    XCTAssertEqual(conflict["error"] as? String, "Choose a different shortcut for single-tap dictation")
    let events = try XCTUnwrap(trace["captureEvents"] as? [String: Any])
    let repeated = try XCTUnwrap(events["repeat"] as? [String: Any])
    XCTAssertEqual(repeated["decoded"] as? Int, 0); XCTAssertEqual(repeated["captured"] as? [String], [])
    let cancel = try XCTUnwrap(events["cancelButton"] as? [String: Any])
    XCTAssertEqual(cancel["label"] as? String, "Cancel"); XCTAssertEqual(cancel["preventedOnMouseDown"] as? Bool, true)
  }

  func testActualVoiceChatAndSingleTapFailuresStayInTheirRowsAndRetryClearsOnlyItsError() async throws {
    let presentation = VoiceShortcutPresentation()
    try await withPage(shortcutPresentation: presentation) { store, window, host in
      store.modelConfiguration.baseURL = "http://127.0.0.1:9/v1"
      store.voicePreferences.realtimeModelID = "fixture-realtime"
      store.voicePreferences.globalHoldHotkey = ShortcutBinding("⌃⌥⇧K")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J"); try await self.settle(host)
      let voice = try await self.startVoiceChatCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(voice))
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertNotNil(presentation.warnings[.voiceChat]); XCTAssertNil(presentation.warnings[.toggle])
      XCTAssertNil(presentation.recording); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let toggle = try await self.startSingleTapCapture(window, host)
      XCTAssertTrue(window.makeFirstResponder(toggle))
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertEqual(presentation.warnings[.toggle], "请为单击听写选择不同的快捷键。")
      XCTAssertNotNil(presentation.warnings[.voiceChat]); XCTAssertNil(presentation.warnings[.hold])
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_VOICE_HOTKEY_ERRORS_RENDER_PATH"] {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
      }
      let retry = try await self.startSingleTapCapture(window, host)
      XCTAssertNil(presentation.warnings[.toggle]); XCTAssertNotNil(presentation.warnings[.voiceChat])
      XCTAssertTrue(window.makeFirstResponder(retry))
      try self.key(.keyDown, 53, "\u{1b}", window); try await self.settle(host)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testActualBareModifierOverlapEndsCaptureAndPreservesSavedBinding() async throws {
    let presentation = VoiceShortcutPresentation()
    try await withPage(shortcutPresentation: presentation) { store, window, host in
      store.voicePreferences.globalHoldHotkey = ShortcutBinding("⌃")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌥⇧"); try await self.settle(host)
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host); XCTAssertTrue(window.makeFirstResponder(capture))
      capture.flagsChanged(with: try self.modifierEvent([.control, .option], window))
      capture.flagsChanged(with: try self.modifierEvent([], window)); try await self.settle(host)
      XCTAssertNil(presentation.recording); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(try XCTUnwrap(presentation.warnings[.toggle]).contains("重叠"))
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌥⇧"))
    }
  }

  func testOldCaptureCallbacksCannotCancelOrWriteIntoNewCaptureOfSameMode() async throws {
    let presentation = VoiceShortcutPresentation()
    try await withPage(shortcutPresentation: presentation) { store, window, host in
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let old = try await self.startSingleTapCapture(window, host); XCTAssertTrue(window.makeFirstResponder(old))
      let receive = try XCTUnwrap(old.receive), blur = try XCTUnwrap(old.onBlur), modifiers = try XCTUnwrap(old.receiveModifier)
      let oldID = presentation.captureID
      try self.key(.keyDown, 53, "\u{1b}", window); try await self.settle(host)
      let current = try await self.startSingleTapCapture(window, host); XCTAssertTrue(window.makeFirstResponder(current))
      let currentID = presentation.captureID; XCTAssertNotEqual(oldID, currentID)
      receive(try self.event(.keyDown, 37, "l", window, [.control, .option, .shift]))
      modifiers(try self.modifierEvent([.control], window)); modifiers(try self.modifierEvent([], window)); blur()
      try await self.settle(host)
      XCTAssertEqual(presentation.captureID, currentID); XCTAssertEqual(presentation.recording, .toggle)
      XCTAssertTrue(window.firstResponder === current); XCTAssertNil(store.voicePreferences.globalToggleHotkey)
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testRepeatedKeyDoesNotConsumeActualCaptureButNextOrdinaryKeySaves() async throws {
    let presentation = VoiceShortcutPresentation()
    try await withPage(shortcutPresentation: presentation) { store, window, host in
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host); XCTAssertTrue(window.makeFirstResponder(capture))
      let id = presentation.captureID
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift], repeating: true); try await self.settle(host)
      XCTAssertEqual(presentation.captureID, id); XCTAssertEqual(store.shortcutCaptureCount, 1)
      XCTAssertNil(store.voicePreferences.globalToggleHotkey)
      try self.key(.keyDown, 40, "k", window, [.control, .option, .shift]); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testRejectedReservedKeyEndsActualCaptureWithoutReplacingExistingBinding() async throws {
    let presentation = VoiceShortcutPresentation()
    try await withPage(shortcutPresentation: presentation) { store, window, host in
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J"); try await self.settle(host)
      XCTAssertTrue(try self.advanced(host).accessibilityPerformPress()); try await self.settle(host)
      let capture = try await self.startSingleTapCapture(window, host); XCTAssertTrue(window.makeFirstResponder(capture))
      // Deliver to the owned recorder boundary; never send a system Quit shortcut.
      capture.keyDown(with: try self.event(.keyDown, 12, "q", window, [.command])); try await self.settle(host)
      XCTAssertNil(presentation.recording); XCTAssertNotNil(presentation.warnings[.toggle])
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  func testSearchRevealsAdvancedAreaInShortViewportWithoutStartingCapture() async throws {
    try await withPage { store, window, host in
      window.setContentSize(.init(width: 400, height: 400)); try await self.settle(host)
      let scroll = try XCTUnwrap(self.descendants(host).compactMap { $0 as? NSScrollView }.first)
      scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); try await self.settle(host)
      let advanced = try self.advanced(host)
      XCTAssertEqual(advanced.bounds.intersection(advanced.visibleRect).height, 0)
      let request = SettingsSearchRequest(result: .init(page: .voice, field: .voiceToggleHotkey))
      host.rootView = VoiceShortcutTestPage(store: store, request: request); try await self.settle(host)
      XCTAssertTrue(advanced.expanded); XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
      XCTAssertGreaterThan(advanced.bounds.intersection(advanced.visibleRect).height, 0)
      XCTAssertEqual(store.shortcutCaptureCount, 0)
    }
  }

  private func advanced(_ host: NSView) throws -> VoiceDictationAdvancedButton.Control {
    try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictationAdvancedButton.Control }.first)
  }
  private func startSingleTapCapture(_ window: NSWindow, _ host: NSView) async throws -> ShortcutCapture.Field {
    let button = try advanced(host); XCTAssertTrue(window.makeFirstResponder(button))
    let tabs = (host as? Host)?.rootView.store.voicePreferences.globalHoldHotkey == nil ? 2 : 3
    for _ in 0..<tabs { try key(.keyDown, 48, "\t", window); try await settle(host) }
    try key(.keyDown, 36, "\r", window); try await settle(host)
    let capture = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertEqual(capture.accessibilityLabel(), "录制单击听写快捷键")
    return capture
  }
  private func startVoiceChatCapture(_ window: NSWindow, _ host: NSView) async throws -> ShortcutCapture.Field {
    let language = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsMenuControl }.first { $0.accessibilityLabel() == "语言" })
    XCTAssertTrue(window.makeFirstResponder(language))
    for _ in 0..<2 { try key(.keyDown, 48, "\t", window); try await settle(host) }
    try key(.keyDown, 36, "\r", window); try await settle(host)
    let capture = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertEqual(capture.accessibilityLabel(), "录制语音聊天快捷键"); return capture
  }
  private typealias Host = NSHostingView<VoiceShortcutTestPage>
  private func withPage(shortcutPresentation: VoiceShortcutPresentation? = nil,
    _ action: (WorkspaceStore, NSWindow, Host) async throws -> Void) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let window = VoiceShortcutTestWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: VoiceShortcutTestPage(store: store, shortcutPresentation: shortcutPresentation))
    window.contentView = host; defer { window.close() }; try await settle(host)
    try await action(store, window, host)
    XCTAssertFalse(window.isVisible)
  }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
  private func key(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ window: NSWindow, _ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws {
    window.sendEvent(try event(type, code, text, window, modifiers, repeating: repeating))
  }
  private func event(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ window: NSWindow, _ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: code))
  }
  private func modifierEvent(_ modifiers: NSEvent.ModifierFlags, _ window: NSWindow) throws -> NSEvent {
    try event(.flagsChanged, 59, "", window, modifiers)
  }
}
@MainActor private final class VoiceShortcutTestWindow: NSWindow { override var canBecomeKey: Bool { true } }
private struct VoiceShortcutTestPage: View {
  let store: WorkspaceStore
  var request: SettingsSearchRequest? = nil
  var shortcutPresentation: VoiceShortcutPresentation? = nil
  var body: some View {
    VoiceSettingsView(store: store, shortcutPresentation: shortcutPresentation).environment(\.appAppearance, store.appearance)
      .environment(\.settingsSearchPresentation, request)
  }
}
