import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsNavigationKeyboardTests: XCTestCase {
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
