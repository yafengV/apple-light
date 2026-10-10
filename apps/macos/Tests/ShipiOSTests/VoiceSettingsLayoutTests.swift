import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceSettingsLayoutTests: XCTestCase {
  func testActualGeneralRowsFollowMicrophoneThenLanguageAtBothWidths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let (window, host) = host(store); defer { window.contentView = nil; window.close() }
    for width: CGFloat in [760, 400] {
      window.setContentSize(.init(width: width, height: 1800)); try await settle(host)
      let controls = descendants(host).compactMap { $0 as? SettingsMenuControl }
      let mic = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "麦克风" })
      let language = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "语言" })
      XCTAssertLessThan(top(mic, in: host), top(language, in: host))
      XCTAssertEqual(mic.convert(mic.bounds, to: host).maxX, width - 36, accuracy: 1)
      XCTAssertEqual(descendants(host).compactMap { $0 as? NSScrollView }.count, 1)
      XCTAssertFalse(window.isVisible)
    }
  }

  func testDictionaryEditorKeepsIdentitySelectionAndDraftDuringCardUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.dictationDictionary = ["ShipiOS"]
    let (window, host) = host(store); defer { window.contentView = nil; window.close() }; try await settle(host)
    let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Jane Doe" })
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.string = "中文未提交词条"
    field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
    editor.setSelectedRange(.init(location: 2, length: 3))
    store.modelConfiguration.baseURL = "http://127.0.0.1:9/v1"
    store.voicePreferences.realtimeModelID = "fixture-realtime"
    window.setContentSize(.init(width: 500, height: 1800)); try await settle(host)
    XCTAssertTrue(field.currentEditor() === editor); XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string, "中文未提交词条"); XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 3))
    XCTAssertTrue(descendants(host).contains { $0 === field })
    window.makeFirstResponder(nil); try await settle(host)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, ["中文未提交词条"])
  }

  func testActualScreenContextUsesReleaseActivationAndPersistsWithoutStartingVoice() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Native Tab traversal requires a visible key window; mandatory in script/test_macos_foreground.py")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.modelConfiguration.baseURL = "http://127.0.0.1:9/v1"
    store.voicePreferences.realtimeModelID = "fixture-realtime"
    let (window, host) = host(store); defer { window.contentView = nil; window.close() }; try await settle(host)
    if ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await settle(host)
      XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(NSApp.isActive)
    } else { window.makeKey() }
    let language = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsMenuControl }.first { $0.accessibilityLabel() == "语言" })
    XCTAssertTrue(window.makeFirstResponder(language))
    for _ in 0..<3 {
      try send(.keyDown, code: 48, text: "\t", to: window); try await settle(host)
    }
    // A failed Tab handoff must fail the test before opening a native menu's
    // synchronous tracking loop. Keep the value and persistence checks below.
    guard window.firstResponder != nil, !(window.firstResponder is SettingsMenuControl) else {
      XCTFail("Tab did not leave the language menu before screen-context activation")
      return
    }
    try send(.keyDown, code: 49, text: " ", to: window); try await settle(host)
    XCTAssertFalse(store.voicePreferences.screenContextEnabled)
    try send(.keyUp, code: 49, text: " ", to: window); try await settle(host)
    XCTAssertTrue(store.voicePreferences.screenContextEnabled)
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
    XCTAssertTrue(restored.voicePreferences.screenContextEnabled)
    XCTAssertFalse(store.voiceChatPresented)
    XCTAssertEqual(window.isVisible, ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1")
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_VOICE_LAYOUT_RENDER_PATH"] {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
  }

  func testActualVoiceHotkeyCaptureSavesAndEscapeLeavesBindingUnchanged() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Native Tab traversal requires a visible key window; mandatory in script/test_macos_foreground.py")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.modelConfiguration.baseURL = "http://127.0.0.1:9/v1"
    store.voicePreferences.realtimeModelID = "fixture-realtime"
    let (window, host) = host(store); defer { window.contentView = nil; window.close() }; try await settle(host)
    if ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await settle(host)
      XCTAssertTrue(window.isKeyWindow); XCTAssertTrue(NSApp.isActive)
    } else { window.makeKey() }
    let language = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsMenuControl }.first { $0.accessibilityLabel() == "语言" })
    for cancel in [false, true] {
      XCTAssertTrue(window.makeFirstResponder(language))
      for _ in 0..<2 { try send(.keyDown, code: 48, text: "\t", to: window); try await settle(host) }
      guard let action = window.firstResponder as? VoiceShortcutActionButton.Control,
        action.kind == .edit else {
        XCTFail("Tab did not reach the hotkey edit action before Return activation")
        return
      }
      try send(.keyDown, code: 36, text: "\r", to: window); try await settle(host)
      let capture = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
      // Inactive hidden windows intentionally do not auto-focus new captures.
      if !window.isKeyWindow { XCTAssertTrue(window.makeFirstResponder(capture)) }
      XCTAssertTrue(window.firstResponder === capture); XCTAssertEqual(store.shortcutCaptureCount, 1)
      if cancel { try send(.keyDown, code: 53, text: "\u{1b}", to: window) }
      else { try send(.keyDown, code: 40, text: "k", modifiers: [.control, .option, .shift], to: window) }
      try await settle(host)
      XCTAssertEqual(store.voicePreferences.globalVoiceChatHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertTrue(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.isEmpty)
    }
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(contentsOf: root.appendingPathComponent("workspace.json")))
    XCTAssertEqual(restored.voicePreferences.globalVoiceChatHotkey, ShortcutBinding("⌃⌥⇧K"))
    XCTAssertFalse(store.voiceChatPresented)
  }

  func testActualRecordingComponentUsesCompactRowHeightFromPublicTypography() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let (id, _) = try XCTUnwrap(store.voiceRecordingHistory.begin())
    store.voiceRecordingHistory.finish(id: id, text: "Fixture transcript", cancelled: false, sizeBytes: 0, recordingError: nil)
    let recording = try XCTUnwrap(store.voiceRecordingHistory.recordings.first)
    _ = NSApplication.shared
    for width: CGFloat in [700, 400] {
      let view = NSHostingView(rootView: VoiceRecordingSettingsRow(store: store, recording: recording, download: {})
        .frame(width: width).environment(\.appAppearance, store.appearance))
      view.frame = .init(x: 0, y: 0, width: width, height: 150)
      try await settle(view)
      // Public compact row: 8+8 insets, 18 4/7+16 line heights and 2 point label gap.
      XCTAssertEqual(view.fittingSize.height, 16 + 130.0 / 7 + 16 + 2, accuracy: 1)
    }
  }

  private func host(_ store: WorkspaceStore) -> (NSWindow, NSView) {
    _ = NSApplication.shared
    let window = VoiceLayoutWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = true
    let view = NSHostingView(rootView: VoiceSettingsView(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = view
    return (window, view)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded() }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func top(_ view: NSView, in host: NSView) -> CGFloat {
    let frame = view.convert(view.bounds, to: host)
    return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
  }
  private func send(_ type: NSEvent.EventType, code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    if ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" {
      NSApp.postEvent(event, atStart: false)
    } else { window.sendEvent(event) }
  }
}
@MainActor private final class VoiceLayoutWindow: NSWindow { override var canBecomeKey: Bool { true } }
