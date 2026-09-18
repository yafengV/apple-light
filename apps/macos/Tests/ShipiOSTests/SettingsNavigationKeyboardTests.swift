import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsNavigationKeyboardTests: XCTestCase {
  func testOnlyUnmodifiedArrowsReachNavigationAndDisabledTargetRejectsFocus() throws {
    let target = SettingsNavigationKeyboardTarget.TargetView()
    var moves: [MoveCommandDirection] = []
    target.onMove = { moves.append($0) }
    func event(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code))
    }
    XCTAssertFalse(target.acceptsFirstResponder)
    XCTAssertFalse(target.handle(try event(125)))
    target.available = true
    XCTAssertTrue(target.acceptsFirstResponder)
    XCTAssertFalse(target.canBecomeKeyView, "The zero-size helper must never be a Tab stop")
    XCTAssertTrue(target.handle(try event(125)))
    XCTAssertTrue(target.handle(try event(126)))
    for flag: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
      XCTAssertFalse(target.handle(try event(125, flags: flag)))
    }
    for key: UInt16 in [0, 48, 53, 123, 124] { XCTAssertFalse(target.handle(try event(key))) }
    XCTAssertEqual(moves, [.down, .up])
    SettingsNavigationKeyboardTarget.dismantleNSView(target, coordinator: ())
    XCTAssertFalse(target.acceptsFirstResponder)
    XCTAssertFalse(target.handle(try event(126)))
  }

  func testNavigationDoesNotWrapAtGroupListEdges() {
    let pages = SettingsNavigation.pages
    XCTAssertNil(SettingsNavigation.adjacent(to: pages.first, offset: -1, in: pages))
    XCTAssertNil(SettingsNavigation.adjacent(to: pages.last, offset: 1, in: pages))
    for index in 0..<(pages.count - 1) {
      XCTAssertEqual(SettingsNavigation.adjacent(to: pages[index], offset: 1, in: pages), pages[index + 1])
      XCTAssertEqual(SettingsNavigation.adjacent(to: pages[index + 1], offset: -1, in: pages), pages[index])
    }
  }
}
