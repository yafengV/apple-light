import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShipiOS

final class GlobalDictationFoundationTests: XCTestCase {
  func testHoldReleaseCancelsPendingStartAndIgnoresRepeatedPress() {
    var state = GlobalDictationHoldState()
    XCTAssertEqual(state.press(newToken: "first"), "first")
    XCTAssertNil(state.press(newToken: "ignored"))
    XCTAssertEqual(state.release(), "first")
    XCTAssertNil(state.token)
    XCTAssertNil(state.release())
    XCTAssertEqual(state.press(newToken: "second"), "second")
    XCTAssertEqual(state.token, "second")
  }

  func testToggleCancelsPendingStartAndRestartsAfterAutomaticCompletion() {
    var state = GlobalDictationToggleState()
    XCTAssertEqual(state.press(activeTarget: nil, newToken: "first"), .start("first"))
    XCTAssertEqual(state.press(activeTarget: nil, newToken: "ignored"), .cancelPending)
    XCTAssertNil(state.token)
    state.didResolveStart(token: "first", active: true)
    XCTAssertNil(state.token, "Late authorization must not revive a canceled shortcut")

    XCTAssertEqual(state.press(activeTarget: nil, newToken: "second"), .start("second"))
    state.didResolveStart(token: "second", active: true)
    XCTAssertEqual(state.press(activeTarget: "second", newToken: "ignored"), .stop("second"))
    XCTAssertNil(state.token)

    XCTAssertEqual(state.press(activeTarget: nil, newToken: "third"), .start("third"))
    state.didResolveStart(token: "third", active: true)
    XCTAssertEqual(state.press(activeTarget: nil, newToken: "fourth"), .start("fourth"),
      "A recognizer that ended by itself must not consume the next toggle press")
  }

  func testInsertionReplacesSelectionAndKeepsUTF16Caret() throws {
    let plan = try XCTUnwrap(GlobalDictationInsertionPlan.make(
      original: "A😀BC", selection: CFRange(location: 3, length: 1), transcript: "你好"))
    XCTAssertEqual(plan.value, "A😀你好C")
    XCTAssertEqual(plan.caret.location, 5)
    XCTAssertEqual(plan.caret.length, 0)
    XCTAssertNil(GlobalDictationInsertionPlan.make(original: "A😀BC",
      selection: CFRange(location: 2, length: 0), transcript: "X"),
      "A caret inside an emoji's surrogate pair must never overwrite the text field")
    XCTAssertNil(GlobalDictationInsertionPlan.make(original: "ABC",
      selection: CFRange(location: 4, length: 0), transcript: "X"))
  }

  @MainActor func testGlobalHotKeyDispatchesPressAndReleaseSeparately() async throws {
    _ = NSApplication.shared
    var presses = 0, releases = 0
    let hotkey = AppGlobalHotKey(id: 19_501, title: "测试按住听写",
      onRelease: { releases += 1 }) { presses += 1 }
    sendHotKeyEvent(kind: UInt32(kEventHotKeyPressed), id: 19_501)
    sendHotKeyEvent(kind: UInt32(kEventHotKeyReleased), id: 19_501)
    try await Task.sleep(for: .milliseconds(50))
    withExtendedLifetime(hotkey) {
      XCTAssertEqual(presses, 1)
      XCTAssertEqual(releases, 1)
    }
  }

  @MainActor private func sendHotKeyEvent(kind: UInt32, id: UInt32) {
    var event: EventRef?
    XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind,
      GetCurrentEventTime(), 0, &event), noErr)
    guard let event else { return }
    defer { ReleaseEvent(event) }
    var identifier = EventHotKeyID(signature: 0x5348_4950, id: id)
    XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
    XCTAssertEqual(SendEventToEventTarget(event, GetApplicationEventTarget()), noErr)
  }
}
