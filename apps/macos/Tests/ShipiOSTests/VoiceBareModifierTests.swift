import AppKit
import XCTest
@testable import ShipiOS

final class VoiceBareModifierTests: XCTestCase {
  func testCaptureAccumulatesModifiersUntilAllKeysAreReleased() {
    var capture = VoiceModifierCaptureState()
    XCTAssertNil(capture.flagsChanged(.control))
    XCTAssertNil(capture.flagsChanged([.control, .option]))
    XCTAssertNil(capture.flagsChanged(.option))
    XCTAssertEqual(capture.flagsChanged([]), ShortcutBinding("⌃⌥"))
    XCTAssertNil(capture.flagsChanged([]))
    XCTAssertTrue(ShortcutBinding("⌃⌥").isBareModifier)
    XCTAssertEqual(ShortcutBinding("⌃⌥").display, "⌃⌥")
  }

  func testKeyDownDiscardsBareModifierCandidate() {
    var capture = VoiceModifierCaptureState()
    XCTAssertNil(capture.flagsChanged(.command))
    capture.reset()
    XCTAssertNil(capture.flagsChanged([]))
  }

  func testHoldPressedOnceAndReleasedWhenModifierIsLifted() {
    var state = VoiceBareModifierState()
    let hold = ShortcutBinding("⌃")
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [.pressHold])
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [])
    XCTAssertEqual(state.flagsChanged([], hold: hold, toggle: nil), [.releaseHold])
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [.pressHold])
    XCTAssertEqual(state.keyDown(currentFlags: .control), [.releaseHold])
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [])
    XCTAssertEqual(state.flagsChanged([], hold: hold, toggle: nil), [])
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [.pressHold])
  }

  func testUnmodifiedTypingDoesNotDisarmNextModifierPress() {
    var state = VoiceBareModifierState()
    XCTAssertEqual(state.keyDown(currentFlags: []), [])
    XCTAssertEqual(state.flagsChanged(.option, hold: ShortcutBinding("⌥"),
      toggle: nil), [.pressHold])
  }

  func testToggleRunsOncePerModifierPress() {
    var state = VoiceBareModifierState()
    let toggle = ShortcutBinding("⌃⌥")
    XCTAssertEqual(state.flagsChanged(.control, hold: nil, toggle: toggle), [])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: toggle), [.toggle])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: toggle), [])
    XCTAssertEqual(state.flagsChanged(.control, hold: nil, toggle: toggle), [])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: toggle), [.toggle])
  }

  func testVoiceChatToggleRunsOnceAndTypingCancelsTheChord() {
    var state = VoiceBareModifierState()
    let voice = ShortcutBinding("⌃⌥")
    XCTAssertEqual(state.flagsChanged(.control, hold: nil, toggle: nil,
      voiceChat: voice), [])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: nil,
      voiceChat: voice), [.voiceChat])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: nil,
      voiceChat: voice), [])
    XCTAssertEqual(state.keyDown(currentFlags: [.control, .option]), [])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: nil,
      voiceChat: voice), [])
    XCTAssertEqual(state.flagsChanged([], hold: nil, toggle: nil,
      voiceChat: voice), [])
    XCTAssertEqual(state.flagsChanged([.control, .option], hold: nil, toggle: nil,
      voiceChat: voice), [.voiceChat])
  }

  func testReconfigurationReleasesHoldAndWaitsForNeutralKeys() {
    var state = VoiceBareModifierState()
    let hold = ShortcutBinding("⇧")
    XCTAssertEqual(state.flagsChanged(.shift, hold: hold, toggle: nil), [.pressHold])
    XCTAssertEqual(state.reset(currentFlags: .shift), [.releaseHold])
    XCTAssertEqual(state.flagsChanged(.shift, hold: hold, toggle: nil), [])
    XCTAssertEqual(state.flagsChanged([], hold: hold, toggle: nil), [])
    XCTAssertEqual(state.flagsChanged(.shift, hold: hold, toggle: nil), [.pressHold])
  }

  func testChangingVoiceChatBindingKeepsActiveHoldUntilItsRelease() {
    var state = VoiceBareModifierState()
    let hold = ShortcutBinding("⌃")
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil), [.pressHold])
    state.reconfigureSecondary(currentFlags: .control)
    XCTAssertEqual(state.flagsChanged(.control, hold: hold, toggle: nil,
      voiceChat: ShortcutBinding("⌥⇧")), [])
    XCTAssertEqual(state.flagsChanged([], hold: hold, toggle: nil,
      voiceChat: ShortcutBinding("⌥⇧")), [.releaseHold])
    XCTAssertEqual(state.flagsChanged([.option, .shift], hold: hold, toggle: nil,
      voiceChat: ShortcutBinding("⌥⇧")), [.voiceChat])
  }
}
