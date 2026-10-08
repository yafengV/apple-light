import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShipiOS

@MainActor final class RegisteredShortcutCaptureTests: XCTestCase {
  func testCarbonCaptureConsumesPressRepeatAndReleaseThenNormalActionWorksAgain() async throws {
    try await withFixture { window, field, key, bindings, counts in
      XCTAssertTrue(window.makeFirstResponder(field))
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyPressed)
      try await self.settle()
      XCTAssertEqual(counts.captured, [bindings[0]]); XCTAssertEqual(counts.actions, 0)
      field.stop()
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyReleased)
      try await self.settle(); XCTAssertEqual(counts.actions, 0); XCTAssertEqual(counts.releases, 0)
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyReleased)
      try await self.settle(); XCTAssertEqual(counts.actions, 2); XCTAssertEqual(counts.releases, 1)
      withExtendedLifetime(key) {}
    }
  }

  func testBlurAndNewFocusCannotReceiveOldQueuedCarbonCapture() async throws {
    try await withFixture { window, field, _, bindings, counts in
      XCTAssertTrue(window.makeFirstResponder(field)); try self.send(kEventHotKeyPressed)
      XCTAssertTrue(window.makeFirstResponder(nil)); XCTAssertTrue(window.makeFirstResponder(field))
      try await self.settle(); XCTAssertTrue(counts.captured.isEmpty); XCTAssertEqual(counts.actions, 0)
      try self.send(kEventHotKeyReleased); try self.send(kEventHotKeyPressed)
      try await self.settle(); XCTAssertEqual(counts.captured, [bindings[0]])
    }
  }

  func testWindowAndApplicationDeactivationRejectPendingCapture() async throws {
    for application in [false, true] {
      try await withFixture { window, field, _, _, counts in
        XCTAssertTrue(window.makeFirstResponder(field)); try self.send(kEventHotKeyPressed)
        if application {
          NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        } else {
          window.keyState = false
          NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        try await self.settle()
        XCTAssertFalse(window.firstResponder === field); XCTAssertTrue(counts.captured.isEmpty)
        XCTAssertEqual(counts.actions, 0)
        try self.send(kEventHotKeyReleased); try await self.settle(); XCTAssertEqual(counts.releases, 0)
      }
    }
  }

  func testChangedRegistrationRejectsOldQueuedCaptureAndUsesNewBinding() async throws {
    try await withFixture { window, field, key, bindings, counts in
      XCTAssertTrue(window.makeFirstResponder(field)); try self.send(kEventHotKeyPressed)
      try key.register(bindings[1]); try await self.settle()
      XCTAssertTrue(counts.captured.isEmpty); XCTAssertEqual(counts.actions, 0)
      try self.send(kEventHotKeyReleased); try self.send(kEventHotKeyPressed); try await self.settle()
      XCTAssertEqual(counts.captured, [bindings[1]])
    }
  }

  func testRegistrationChangeDuringCaptureStillConsumesItsPairedRelease() async throws {
    try await withFixture { window, field, key, bindings, counts in
      XCTAssertTrue(window.makeFirstResponder(field)); try self.send(kEventHotKeyPressed)
      try key.register(bindings[1]); field.stop()
      try self.send(kEventHotKeyReleased); try await self.settle()
      XCTAssertTrue(counts.captured.isEmpty); XCTAssertEqual(counts.actions, 0)
      XCTAssertEqual(counts.releases, 0)
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyReleased); try await self.settle()
      XCTAssertEqual(counts.actions, 1); XCTAssertEqual(counts.releases, 1)
    }
  }

  func testNormalActionQueuedBeforeRecordingCannotFireInsideNewCapture() async throws {
    try await withFixture { window, field, _, _, counts in
      try self.send(kEventHotKeyPressed)
      XCTAssertTrue(window.makeFirstResponder(field))
      try await self.settle()
      XCTAssertEqual(counts.actions, 0); XCTAssertTrue(counts.captured.isEmpty)
      try self.send(kEventHotKeyReleased); try await self.settle()
      XCTAssertEqual(counts.releases, 1, "An ordinary hold release must remain available to stop a preexisting hold")
    }
  }

  func testNonKeyWindowRecorderDoesNotReceiveCarbonEvent() async throws {
    try await withFixture { window, field, _, _, counts in
      XCTAssertTrue(window.makeFirstResponder(field)); window.keyState = false
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyReleased); try await self.settle()
      XCTAssertTrue(counts.captured.isEmpty); XCTAssertEqual(counts.actions, 1); XCTAssertEqual(counts.releases, 1)
    }
  }

  func testRecorderWithoutRegisteredReceiverStillSuppressesOriginalAction() async throws {
    try await withFixture { window, field, _, _, counts in
      field.receiveRegistered = nil
      XCTAssertTrue(window.makeFirstResponder(field))
      try self.send(kEventHotKeyPressed); try self.send(kEventHotKeyReleased); try await self.settle()
      XCTAssertTrue(counts.captured.isEmpty); XCTAssertEqual(counts.actions, 0); XCTAssertEqual(counts.releases, 0)
    }
  }

  private final class Counts {
    var captured: [ShortcutBinding] = []
    var actions = 0
    var releases = 0
  }
  private final class Window: NSWindow {
    var keyState = true
    override var isKeyWindow: Bool { keyState }
    override var canBecomeKey: Bool { true }
  }
  private func withFixture(_ action: (Window, ShortcutCapture.Field, AppGlobalHotKey,
    [ShortcutBinding], Counts) async throws -> Void) async throws {
    _ = NSApplication.shared
    let window = Window(contentRect: .init(x: 0, y: 0, width: 300, height: 80),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = ShortcutCapture.Field(); field.frame = .init(x: 10, y: 10, width: 144, height: 28)
    let root = NSView(frame: window.contentLayoutRect); root.addSubview(field); window.contentView = root
    defer { field.stop(); window.close() }
    field.install()
    let counts = Counts(); field.receiveRegistered = { counts.captured.append($0) }
    let key = AppGlobalHotKey(id: 68_420, title: "录制测试", onRelease: { counts.releases += 1 }) { counts.actions += 1 }
    var bindings: [ShortcutBinding] = []
    for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
      let binding = ShortcutBinding("⌘⌃⌥⇧" + digit)
      do { try key.register(binding); try key.register(nil); bindings.append(binding) } catch { continue }
      if bindings.count == 2 { break }
    }
    XCTAssertEqual(bindings.count, 2); guard bindings.count == 2 else { return }
    try key.register(bindings[0])
    // Undo the recorder's deferred initial autofocus for the ordinary-action case.
    try await settle(); XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertTrue(NSApp.windows.contains { $0 === window })
    try await action(window, field, key, bindings, counts)
    XCTAssertFalse(window.isVisible)
    withExtendedLifetime(key) {}
  }
  private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }
  private func send(_ kind: Int) throws {
    var event: EventRef?
    XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), GetCurrentEventTime(), 0, &event), noErr)
    let value = try XCTUnwrap(event); defer { ReleaseEvent(value) }
    var identifier = EventHotKeyID(signature: 0x5348_4950, id: 68_420)
    XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
    XCTAssertEqual(SendEventToEventTarget(value, GetApplicationEventTarget()), noErr)
  }
}
