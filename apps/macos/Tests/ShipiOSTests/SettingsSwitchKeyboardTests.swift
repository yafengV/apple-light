import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsSwitchKeyboardTests: XCTestCase {
  func testNativeTabThenImmediateSpaceActivatesTheNewSwitch() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and an actual key window")
    }
    let state = SwitchKeyboardState(); state.secondVisible = true
    let (window, host) = host(state)
    defer { window.close() }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await settle(host)
    XCTAssertTrue(window.isKeyWindow)
    XCTAssertTrue(window.makeFirstResponder(host))
    window.selectNextKeyView(nil)
    try await settle(host)
    let first = try XCTUnwrap(window.firstResponder)
    try send(.keyDown, code: 48, characters: "\t", in: window)
    XCTAssertTrue(window.firstResponder !== first)
    try send(.keyDown, code: 49, characters: " ", in: window)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value)
    XCTAssertTrue(state.secondValue, "The first Space after Tab must activate the new focus target")
    XCTAssertEqual(state.writes, 0)
    try send(.keyDown, code: 48, characters: "\u{19}", modifiers: .shift, in: window)
    XCTAssertTrue(window.firstResponder === first)
    try send(.keyDown, code: 36, characters: "\r", in: window)
    try send(.keyUp, code: 36, characters: "\r", in: window)
    try await settle(host)
    XCTAssertTrue(state.value, "Enter must also work immediately after Shift-Tab")
    XCTAssertEqual(state.writes, 1)
    try send(.keyDown, code: 49, characters: " ", in: window)
    try send(.keyDown, code: 48, characters: "\t", in: window)
    XCTAssertTrue(window.firstResponder !== first, "Held-Space cancellation must actually move native focus")
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertTrue(state.secondValue, "Release on a different switch must not activate it")
    XCTAssertTrue(state.value)
    XCTAssertEqual(state.writes, 1)
  }

  func testSpaceCommitsOnlyOnReleaseAndHoldingDoesNotWrite() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
    try send(.keyDown, code: 49, characters: " ", repeatKey: true, in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  func testEnterCommitsOnPressWithoutASecondReleaseWrite() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 36, characters: "\r", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
    try send(.keyUp, code: 36, characters: "\r", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  func testRepeatedSpaceOnCurrentFocusArmsUntilRelease() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", repeatKey: true, in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  func testKeypadEnterCommitsOnPressWithoutASecondReleaseWrite() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 76, characters: "\u{3}", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
    try send(.keyUp, code: 76, characters: "\u{3}", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  func testEnterRepeatActivatesAgainAfterInitialPress() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 36, characters: "\r", in: window)
    try await settle(host)
    try send(.keyDown, code: 36, characters: "\r", repeatKey: true, in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 2)
  }

  func testRejectedBindingIsReadAgainInsteadOfOptimisticallyToggled() async throws {
    let state = SwitchKeyboardState(); state.rejectWrites = true
    let (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 36, characters: "\r", in: window)
    try await settle(host)
    try send(.keyDown, code: 36, characters: "\r", repeatKey: true, in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
    XCTAssertEqual(state.requests, [true, true])
  }

  func testMovingNativeFocusAwayAndBackCancelsPendingSpace() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    let switchResponder = try XCTUnwrap(window.firstResponder)
    try send(.keyDown, code: 49, characters: " ", in: window)
    // Hidden windows do not reliably dispatch Tab through the application's
    // key loop. Actual Tab events are covered by the foreground test above.
    window.selectNextKeyView(nil)
    try await settle(host)
    XCTAssertTrue(window.firstResponder !== switchResponder, "Native focus must actually leave the switch")
    window.selectPreviousKeyView(nil)
    try await settle(host)
    XCTAssertTrue(window.firstResponder === switchResponder, "Native focus must return to the same retained switch")
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
  }

  func testDisableAndReenableCancelsPendingSpace() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    state.enabled = false; try await settle(host)
    state.enabled = true; try await focus(window, host)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
  }

  func testRemovingAndRecreatingControlCancelsPendingSpace() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    state.visible = false; try await settle(host)
    state.visible = true; try await focus(window, host)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
  }

  func testResigningWindowBeforeSpaceReleaseDoesNotWriteOnReturn() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    let responder = try XCTUnwrap(window.firstResponder)
    window.resignKey(); try await settle(host)
    window.makeKey(); try await settle(host)
    XCTAssertTrue(window.firstResponder === responder, "Do not cancel merely by explicitly moving focus")
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
  }

  func testApplicationDeactivationCancelsPendingSpace() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertFalse(state.value); XCTAssertEqual(state.writes, 0)
  }

  func testAnotherWindowsNotificationDoesNotCancelCurrentPress() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { window.close(); other.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", in: window)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
    try send(.keyUp, code: 49, characters: " ", in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  func testShiftSpaceActivatesOnceAndCommandSpaceDoesNotWrite() async throws {
    let state = SwitchKeyboardState(), (window, host) = host(state)
    defer { window.close() }; try await focus(window, host)
    try send(.keyDown, code: 49, characters: " ", modifiers: .shift, in: window)
    try send(.keyUp, code: 49, characters: " ", modifiers: .shift, in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
    try send(.keyDown, code: 49, characters: " ", modifiers: .command, in: window)
    try send(.keyUp, code: 49, characters: " ", modifiers: .command, in: window)
    try await settle(host)
    XCTAssertTrue(state.value); XCTAssertEqual(state.writes, 1)
  }

  private func host(_ state: SwitchKeyboardState) -> (NSWindow, NSView) {
    _ = NSApplication.shared
    let window = SwitchKeyboardWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: SwitchKeyboardFixture(state: state).padding(20))
    window.contentView = host
    return (window, host)
  }
  private func focus(_ window: NSWindow, _ host: NSView) async throws {
    try await settle(host)
    window.makeKey()
    XCTAssertTrue(window.makeFirstResponder(host))
    window.selectNextKeyView(nil)
    try await settle(host)
    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(window.firstResponder !== window)
  }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
  private func send(_ type: NSEvent.EventType, code: UInt16, characters: String, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
    _ = try XCTUnwrap(window.firstResponder)
    window.sendEvent(event)
  }
}
@MainActor @Observable private final class SwitchKeyboardState {
  var value = false { didSet { writes += 1 } }
  var enabled = true
  var visible = true
  var secondVisible = false
  var secondValue = false
  var rejectWrites = false
  var requests: [Bool] = []
  var writes = 0
}
private struct SwitchKeyboardFixture: View {
  @Bindable var state: SwitchKeyboardState
  var body: some View {
    VStack {
      if state.visible {
        Toggle("Keyboard switch", isOn: valueBinding($state.value))
          .toggleStyle(SettingsSwitchStyle()).disabled(!state.enabled)
      }
      if state.secondVisible {
        Toggle("Second switch", isOn: $state.secondValue).toggleStyle(SettingsSwitchStyle())
      }
      Button("Next control") {}.buttonStyle(SettingsActionButtonStyle())
    }
  }
  private func valueBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
    .init(get: { binding.wrappedValue }, set: { value in
      state.requests.append(value)
      if !state.rejectWrites { binding.wrappedValue = value }
    })
  }
}
@MainActor private final class SwitchKeyboardWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}
