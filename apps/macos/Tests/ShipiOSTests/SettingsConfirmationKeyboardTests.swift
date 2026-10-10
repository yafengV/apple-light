import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsConfirmationKeyboardTests: XCTestCase {
  func testNativeRapidConfirmationKeysUseTheLatestSelection() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and an actual key window")
    }
    let state = ConfirmationKeyboardState()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 430),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ConfirmationKeyboardFixture(state: state))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    }
    func post(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
      }
    }
    for appshot in [false, true] {
      state.showing = false; state.appshot = appshot
      try await settle()
      for (tabs, shift, code, characters, confirms) in [
        (1, false, UInt16(36), "\r", true),
        (2, false, UInt16(36), "\r", false),
        (1, true, UInt16(36), "\r", true),
        (1, false, UInt16(49), " ", true),
        (1, false, UInt16(53), "\u{1b}", false),
      ] {
        state.showing = true
        try await settle()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertNil(window.attachedSheet)
        let beforeConfirm = state.confirmed, beforeCancel = state.cancelled
        // Queue the entire sequence without yielding to SwiftUI rendering.
        for _ in 0..<tabs { try post(48, shift ? "\u{19}" : "\t", flags: shift ? .shift : []) }
        try post(code, characters)
        try await settle()
        XCTAssertEqual(state.confirmed - beforeConfirm, confirms ? 1 : 0, "tabs=\(tabs), key=\(code), shift=\(shift)")
        XCTAssertEqual(state.cancelled - beforeCancel, confirms ? 0 : 1)
        XCTAssertFalse(state.showing)
      }
      state.showing = true
      try await settle()
      let counts = (state.confirmed, state.cancelled)
      try post(36, "\r", flags: .command)
      try await settle()
      XCTAssertEqual(state.confirmed, counts.0); XCTAssertEqual(state.cancelled, counts.1)
      XCTAssertTrue(state.showing)
      try post(13, "w", flags: .command)
      try await settle()
      XCTAssertEqual(state.cancelled, counts.1 + 1)
      XCTAssertFalse(state.showing); XCTAssertTrue(window.isVisible)
    }
    state.appshot = false
    state.showing = true; state.busy = true
    try await settle()
    let counts = (state.confirmed, state.cancelled)
    try post(48, "\t"); try post(36, "\r"); try post(53, "\u{1b}")
    try await settle()
    XCTAssertEqual(state.confirmed, counts.0); XCTAssertEqual(state.cancelled, counts.1)
    XCTAssertTrue(state.showing)
  }
}

@MainActor @Observable private final class ConfirmationKeyboardState {
  var showing = true
  var appshot = false
  var busy = false
  var confirmed = 0
  var cancelled = 0
}

private struct ConfirmationKeyboardFixture: View {
  let state: ConfirmationKeyboardState
  var body: some View {
    Color.gray.overlay {
      if state.showing {
        if state.appshot {
          AppshotIntroDialog(cancel: { state.cancelled += 1; state.showing = false },
            enable: { state.confirmed += 1; state.showing = false })
        } else {
        SettingsConfirmationDialog(title: "丢弃更改？", message: "原生键盘验收",
          confirmLabel: "丢弃更改", busyLabel: "正在执行…", busy: state.busy,
          error: nil, width: 420, identifier: "confirmation-keyboard-test",
          cancel: { state.cancelled += 1; state.showing = false },
          confirm: { state.confirmed += 1; state.showing = false })
        }
      }
    }
  }
}
