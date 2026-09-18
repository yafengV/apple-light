import AppKit
import XCTest
@testable import ShipiOS

final class MessageWebLinkBehaviorTests: XCTestCase {
  func testGesturesAndExternalPreferencePriority() throws {
    let url = try XCTUnwrap(URL(string: "https://example.invalid"))
    func resolve(_ flags: NSEvent.ModifierFlags = [], button: Int = 0,
      target: WebLinkTarget = .inAppBrowser,
      shortcut: ExternalBrowserLinkShortcut = .unassigned) -> MessageWebLinkBehavior {
      .resolve(url: url, click: .init(modifiers: flags, button: button), preference: target, shortcut: shortcut)
    }
    XCTAssertEqual(resolve(), .inApp(.split))
    XCTAssertEqual(resolve(.command), .inApp(.backgroundTab))
    XCTAssertEqual(resolve([.command, .shift]), .inApp(.foregroundTab))
    XCTAssertEqual(resolve([.command, .option]), .inApp(.fullWidth))
    XCTAssertEqual(resolve(button: 1), .inApp(.backgroundTab))
    XCTAssertEqual(resolve(.shift, button: 1), .inApp(.foregroundTab))
    XCTAssertEqual(resolve(target: .externalBrowser), .external)
    XCTAssertEqual(resolve(.command, target: .externalBrowser), .inApp(.backgroundTab))
    XCTAssertEqual(resolve(.command, shortcut: .primary), .external)
    XCTAssertEqual(resolve([.command, .shift], shortcut: .primaryShift), .external)
    XCTAssertEqual(resolve(.option, shortcut: .alt), .external)
    XCTAssertEqual(resolve(.option), .download)
    XCTAssertEqual(resolve(.option, target: .externalBrowser), .download)
    XCTAssertEqual(resolve([.option, .shift]), .inApp(.split))
    XCTAssertEqual(resolve([.option, .control]), .inApp(.split))
    XCTAssertEqual(resolve([.command, .option], target: .externalBrowser, shortcut: .primary), .inApp(.fullWidth))
    XCTAssertEqual(resolve([.command, .option, .shift]), .inApp(.foregroundTab))
    XCTAssertEqual(resolve([.command, .control], shortcut: .primary), .inApp(.backgroundTab))
    XCTAssertEqual(MessageWebLinkBehavior.resolve(url: URL(string: "mailto:test@example.invalid")!,
      click: .init(modifiers: [.command, .option]), preference: .inAppBrowser, shortcut: .unassigned), .external)
  }

  @MainActor func testBackgroundCreationDoesNotPublishSelectionOrFocusChanges() {
    let browser = BrowserSession()
    defer { browser.shutdown() }
    var opened: [UUID] = []
    var selected: [UUID] = []
    browser.onTabOpened = { opened.append($0) }
    browser.onTabSelected = { selected.append($0) }
    let original = browser.newTab()
    let addressFocus = browser.addressFocus
    let contentFocus = browser.contentFocus
    let background = browser.newTab(activate: false)
    XCTAssertEqual(opened, [original.id, background.id])
    XCTAssertEqual(selected, [original.id])
    XCTAssertEqual(browser.selection, original.id)
    XCTAssertEqual(browser.addressFocus, addressFocus)
    XCTAssertEqual(browser.contentFocus, contentFocus)
    browser.select(background.id)
    XCTAssertEqual(selected, [original.id, background.id])
  }
}
