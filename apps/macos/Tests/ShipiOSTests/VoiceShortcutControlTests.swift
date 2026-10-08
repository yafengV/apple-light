import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceShortcutControlTests: XCTestCase {
  func testActualPageHasNamedEditAndConditionalClearAndCancelControls() async throws {
    try await withPage { store, _, host, _ in
      XCTAssertEqual(try self.button("edit-hold", host).accessibilityLabel(), "设置按住听写快捷键")
      XCTAssertEqual(try self.button("edit-voiceChat", host).accessibilityLabel(), "设置语音聊天快捷键")
      XCTAssertNil(self.find("clear-hold", host)); XCTAssertNil(self.find("edit-toggle", host))
      try await self.expand(host)
      XCTAssertEqual(try self.button("edit-toggle", host).accessibilityLabel(), "设置单击听写快捷键")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J"); try await self.settle(host)
      XCTAssertEqual(try self.button("edit-toggle", host).accessibilityLabel(), "更改单击听写快捷键")
      XCTAssertEqual(try self.button("clear-toggle", host).accessibilityLabel(), "清除单击听写快捷键")
      XCTAssertTrue(try self.button("edit-toggle", host).accessibilityPerformPress()); try await self.settle(host)
      XCTAssertNil(self.find("edit-toggle", host)); XCTAssertNil(self.find("clear-toggle", host))
      XCTAssertEqual(try self.button("cancel-toggle", host).accessibilityLabel(), "取消录制单击听写快捷键")
    }
  }

  func testActualClearIsTabReachableAndSpaceReleasePersistsOnlyItsBinding() async throws {
    try await withPage { store, window, host, _ in
      store.voicePreferences.globalHoldHotkey = ShortcutBinding("⌃⌥⇧K")
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      store.voicePreferences.globalVoiceChatHotkey = ShortcutBinding("⌃⌥⇧V")
      try await self.settle(host); try await self.expand(host)
      let edit = try self.button("edit-toggle", host), clear = try self.button("clear-toggle", host)
      XCTAssertTrue(window.makeFirstResponder(edit)); try self.key(.keyDown, 48, "\t", window)
      XCTAssertTrue(window.firstResponder === clear)
      try self.key(.keyDown, 49, " ", window); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      try self.key(.keyUp, 49, " ", window); try await self.settle(host)
      XCTAssertNil(store.voicePreferences.globalToggleHotkey)
      XCTAssertEqual(store.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertEqual(store.voicePreferences.globalVoiceChatHotkey, ShortcutBinding("⌃⌥⇧V"))
      let saved = try JSONDecoder().decode(WorkspaceLibrary.self,
        from: Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")))
      XCTAssertNil(saved.voicePreferences.globalToggleHotkey)
      XCTAssertEqual(saved.voicePreferences.globalHoldHotkey, ShortcutBinding("⌃⌥⇧K"))
      XCTAssertNil(self.find("clear-toggle", host)); XCTAssertNotNil(self.find("edit-toggle", host))
    }
  }

  func testActualCancelPointerDownRetainsRecorderAndReleaseCancelsWithoutSaving() async throws {
    try await withPage { store, window, host, presentation in
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      var registrations = 0; store.globalDictationHotkeyChangeHandler = { registrations += 1 }
      try await self.settle(host); try await self.expand(host)
      let field = try await self.begin("toggle", window, host)
      let cancel = try self.button("cancel-toggle", host)
      let center = cancel.convert(.init(x: cancel.bounds.midX, y: cancel.bounds.midY), to: nil)
      let parent = try XCTUnwrap(cancel.superview)
      XCTAssertTrue(cancel.hitTest(cancel.convert(.init(x: cancel.bounds.midX, y: cancel.bounds.midY), to: parent)) === cancel)
      cancel.mouseDown(with: try self.mouse(.leftMouseDown, center, window))
      XCTAssertTrue(window.firstResponder === field); XCTAssertEqual(store.shortcutCaptureCount, 1)
      XCTAssertEqual(presentation.recording, .toggle)
      cancel.mouseUp(with: try self.mouse(.leftMouseUp, center, window)); try await self.settle(host)
      XCTAssertNil(presentation.recording); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      XCTAssertEqual(registrations, 0); XCTAssertNil(self.find("cancel-toggle", host))
      XCTAssertNotNil(self.find("clear-toggle", host))
    }
  }

  func testCancelReleaseOutsideAndWindowDeactivationDoNotInvokeStalePointerPress() async throws {
    try await withPage { store, window, host, presentation in
      try await self.expand(host); let field = try await self.begin("toggle", window, host)
      let cancel = try self.button("cancel-toggle", host)
      let center = cancel.convert(.init(x: cancel.bounds.midX, y: cancel.bounds.midY), to: nil)
      cancel.mouseDown(with: try self.mouse(.leftMouseDown, center, window))
      cancel.mouseUp(with: try self.mouse(.leftMouseUp, .init(x: -20, y: -20), window))
      XCTAssertEqual(presentation.recording, .toggle); XCTAssertTrue(window.firstResponder === field)
      cancel.mouseDown(with: try self.mouse(.leftMouseDown, center, window))
      NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
      cancel.mouseUp(with: try self.mouse(.leftMouseUp, center, window)); try await self.settle(host)
      XCTAssertEqual(presentation.recording, .toggle); XCTAssertEqual(store.shortcutCaptureCount, 1)
      XCTAssertTrue(cancel.accessibilityPerformPress()); try await self.settle(host)
      XCTAssertNil(presentation.recording); XCTAssertEqual(store.shortcutCaptureCount, 0)
      XCTAssertNil(store.voicePreferences.globalToggleHotkey)
    }
  }

  func testOldCancelCallbackCannotEndAReplacementCapture() async throws {
    try await withPage { _, window, host, presentation in
      try await self.expand(host); _ = try await self.begin("toggle", window, host)
      let cancel = try self.button("cancel-toggle", host), stale = try XCTUnwrap(cancel.activate)
      XCTAssertTrue(cancel.accessibilityPerformPress()); try await self.settle(host)
      let replacement = try await self.begin("toggle", window, host), id = presentation.captureID
      stale(); try await self.settle(host)
      XCTAssertEqual(presentation.captureID, id); XCTAssertEqual(presentation.recording, .toggle)
      XCTAssertTrue(window.firstResponder === replacement)
    }
  }

  func testPendingClearSpaceCancelsOnBlurAndRepeatAloneCannotClear() async throws {
    try await withPage { store, window, host, _ in
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      try await self.settle(host); try await self.expand(host)
      let edit = try self.button("edit-toggle", host), clear = try self.button("clear-toggle", host)
      XCTAssertTrue(window.makeFirstResponder(clear)); try self.key(.keyDown, 49, " ", window)
      XCTAssertTrue(window.makeFirstResponder(edit)); clear.keyUp(with: try self.event(.keyUp, 49, " ", window))
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      XCTAssertTrue(window.makeFirstResponder(clear))
      clear.keyDown(with: try self.event(.keyDown, 49, " ", window, repeatKey: true))
      clear.keyUp(with: try self.event(.keyUp, 49, " ", window)); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.globalToggleHotkey, ShortcutBinding("⌃⌥⇧J"))
      try self.key(.keyDown, 76, "\r", window); try await self.settle(host)
      XCTAssertNil(store.voicePreferences.globalToggleHotkey)
    }
  }

  func testNarrowRTLActualClearReceivesFocusRevealAndCaptureCancelFits() async throws {
    try await withPage { store, window, host, _ in
      store.voicePreferences.globalToggleHotkey = ShortcutBinding("⌃⌥⇧J")
      host.rootView.direction = .rightToLeft; window.setContentSize(.init(width: 400, height: 400))
      try await self.settle(host); try await self.expand(host)
      let edit = try self.button("edit-toggle", host), clear = try self.button("clear-toggle", host)
      XCTAssertEqual(clear.userInterfaceLayoutDirection, .rightToLeft)
      XCTAssertTrue(window.makeFirstResponder(clear)); try await self.settle(host)
      XCTAssertGreaterThan(clear.bounds.intersection(clear.visibleRect).height, 0)
      XCTAssertGreaterThan(edit.convert(edit.bounds, to: host).midX, clear.convert(clear.bounds, to: host).midX)
      _ = try await self.begin("toggle", window, host)
      let cancel = try self.button("cancel-toggle", host)
      let rect = cancel.convert(cancel.bounds, to: host)
      XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, 400)
      XCTAssertEqual(cancel.bounds.height, 28, accuracy: 0.5)
    }
  }

  func testActualReferenceUsesSeparateEditClearAndCaptureOnlyCancel() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_shortcut_controls_reference_681",
      withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    for (name, labels) in [("empty", ["Set shortcut for Dictation"]),
      ("bound", ["Change shortcut for Dictation", "Clear shortcut for Dictation"]), ("capturing", ["Cancel"])] {
      let state = try XCTUnwrap(fixture[name] as? [String: Any])
      let buttons = try XCTUnwrap(state["buttons"] as? [[String: Any]])
      XCTAssertEqual(buttons.compactMap { $0["label"] as? String }, labels)
      XCTAssertTrue(buttons.allSatisfy { $0["color"] as? String == "ghost" && $0["size"] as? String == "toolbar" })
      if name == "capturing" { XCTAssertEqual(buttons[0]["preventsMouseDown"] as? Bool, true) }
    }
    let bound = try XCTUnwrap(fixture["bound"] as? [String: Any])
    XCTAssertEqual(bound["keycap"] as? String, "!px-2 !py-1 !text-sm")
    let disabled = try XCTUnwrap(fixture["disabled"] as? [String: Any])
    XCTAssertTrue(try XCTUnwrap(disabled["buttons"] as? [[String: Any]]).allSatisfy { $0["disabled"] as? Bool == true })
  }

  func testNativeGhostSymbolsAndCancelPreserveThemeForegroundAlphaAndDisabledDimming() throws {
    var preferences = AppearancePreferences(); preferences.theme = "dark"; preferences.dark.foreground = "#FFFFFF"
    let expected = preferences.resolvedColors["textForegroundTertiary"].alpha
    for kind in [VoiceShortcutActionButton.Kind.edit, .clear, .cancel] {
      let control = VoiceShortcutActionButton.Control(frame: .init(x: 0, y: 0, width: 60, height: 28))
      control.kind = kind; control.title = kind == .cancel ? "取消" : ""; control.preferences = preferences
      func peak(_ enabled: Bool) throws -> Double {
        control.isEnabled = enabled
        let image = NSImage(size: control.bounds.size, flipped: false) { rect in
          NSColor.black.setFill(); rect.fill(); control.draw(rect); return true
        }
        var rect = control.bounds
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        var red = 0.0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
          // Inspect the bitmap's encoded neutral channels without reinterpreting
          // colorAt's calibrated-RGB label as a new source profile.
          let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
          red = max(red, pixel.redComponent)
        } }
        return red
      }
      let normal = try peak(true), disabled = try peak(false)
      XCTAssertLessThanOrEqual(normal, expected + 0.04)
      XCTAssertGreaterThan(normal, expected * 0.6)
      XCTAssertLessThanOrEqual(disabled, expected * 0.4 + 0.04)
      XCTAssertGreaterThan(disabled, expected * 0.2)
    }
  }

  private typealias Host = NSHostingView<ShortcutControlsPage>
  private func withPage(_ action: (WorkspaceStore, NSWindow, Host, VoiceShortcutPresentation) async throws -> Void) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let presentation = VoiceShortcutPresentation()
    let window = ShortcutControlsWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 1800),
      styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ShortcutControlsPage(store: store, presentation: presentation))
    window.contentView = host; defer { window.close() }; try await settle(host)
    try await action(store, window, host, presentation); XCTAssertFalse(window.isVisible)
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func find(_ id: String, _ host: NSView) -> VoiceShortcutActionButton.Control? {
    descendants(host).compactMap { $0 as? VoiceShortcutActionButton.Control }
      .first { $0.accessibilityIdentifier() == "voice-hotkey-" + id }
  }
  private func button(_ id: String, _ host: NSView) throws -> VoiceShortcutActionButton.Control { try XCTUnwrap(find(id, host)) }
  private func expand(_ host: NSView) async throws {
    let control = try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictationAdvancedButton.Control }.first)
    if !control.expanded { XCTAssertTrue(control.accessibilityPerformPress()); try await settle(host) }
  }
  private func begin(_ mode: String, _ window: NSWindow, _ host: NSView) async throws -> ShortcutCapture.Field {
    XCTAssertTrue(try button("edit-" + mode, host).accessibilityPerformPress()); try await settle(host)
    let field = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutCapture.Field }.first)
    XCTAssertTrue(window.makeFirstResponder(field)); return field
  }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
  private func event(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ window: NSWindow, repeatKey: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code))
  }
  private func key(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ window: NSWindow) throws {
    window.sendEvent(try event(type, code, text, window))
  }
  private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
  }
}
@MainActor private final class ShortcutControlsWindow: NSWindow { override var canBecomeKey: Bool { true } }
private struct ShortcutControlsPage: View {
  let store: WorkspaceStore
  let presentation: VoiceShortcutPresentation
  var direction = LayoutDirection.leftToRight
  var body: some View {
    ScrollViewReader { proxy in
      VoiceSettingsView(store: store, shortcutPresentation: presentation)
        .environment(\.settingsRevealFocusedControl, { id in proxy.scrollTo(id) })
        .environment(\.appAppearance, store.appearance).environment(\.layoutDirection, direction)
    }
  }
}
