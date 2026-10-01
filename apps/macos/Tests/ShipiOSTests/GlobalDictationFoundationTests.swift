import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShipiOS

final class GlobalDictationFoundationTests: XCTestCase {
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
