import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class ExternalBrowserShortcutTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testAllModifierCombinationsAndButtonsMatchReferenceRules() {
    let flags: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
    for shortcut in ExternalBrowserLinkShortcut.allCases {
      for mask in 0..<16 {
        let combination = flags.enumerated().reduce(into: NSEvent.ModifierFlags()) {
          if mask & (1 << $1.offset) != 0 { $0.formUnion($1.element) }
        }
        let expected = (shortcut == .primary && mask == 1)
          || (shortcut == .alt && mask == 4) || (shortcut == .primaryShift && mask == 9)
        for button in 0...2 {
          XCTAssertEqual(shortcut.matches(.init(modifiers: combination, button: button)),
            expected && button == 0, "\(shortcut) mask=\(mask) button=\(button)")
        }
      }
      XCTAssertFalse(shortcut.matches(nil))
    }
    XCTAssertTrue(ExternalBrowserLinkShortcut.primary.matches(.init(modifiers: [.command, .capsLock])))
  }

  func testActivationCapturesMouseEventAndIgnoresKeyboardEvents() throws {
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
      modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 0))
    XCTAssertTrue(ExternalBrowserLinkShortcut.primaryShift.matches(WebLinkClick(event: event)))
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    XCTAssertNil(WebLinkClick(event: key))
    XCTAssertNil(WebLinkClick(event: nil))
  }

  func testPreviousVersionDefaultsThenRoundTripsAndResetsOnlyRelevantPreferences() async throws {
    let directory = try root()
    let file = directory.appendingPathComponent("shortcuts.json")
    try Data(#"{"version":1,"primaryNumberShortcutTarget":"sidebar","overrides":{}}"#.utf8).write(to: file)
    let store = WorkspaceStore(dataRoot: directory)
    XCTAssertEqual(store.shortcuts.primaryNumberShortcutTarget, .sidebar)
    XCTAssertEqual(store.shortcuts.externalBrowserLinkShortcut, .unassigned)
    XCTAssertFalse(store.shortcuts.hasCustomizations)
    try store.shortcuts.setExternalBrowserLinkShortcut(.primaryShift)
    XCTAssertTrue(store.shortcuts.hasCustomizations)
    XCTAssertTrue(store.shortcuts.overrides.isEmpty)
    XCTAssertEqual(ShortcutPreferences(file: file).externalBrowserLinkShortcut, .primaryShift)
    store.requestShortcutReset()
    XCTAssertTrue(store.shortcutResetRequested, "The link preference alone must enable reset")
    await store.confirmShortcutReset()
    XCTAssertFalse(store.shortcutResetRequested)
    let saved = ShortcutPreferences(file: file)
    XCTAssertEqual(saved.externalBrowserLinkShortcut, .unassigned)
    XCTAssertEqual(saved.primaryNumberShortcutTarget, .sidebar)
  }

  func testFailedWriteAndResetKeepBindingAndLinkPreferenceTogether() async throws {
    let directory = try root()
    let store = WorkspaceStore(dataRoot: directory)
    let file = directory.appendingPathComponent("shortcuts.json")
    try store.shortcuts.setExternalBrowserLinkShortcut(.alt)
    try store.shortcuts.set(ShortcutBinding("⌘⇧L"), for: "search")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.shortcuts.setExternalBrowserLinkShortcut(.primary))
    XCTAssertEqual(store.shortcuts.externalBrowserLinkShortcut, .alt)
    store.requestShortcutReset()
    await store.confirmShortcutReset()
    XCTAssertTrue(store.shortcutResetRequested)
    XCTAssertNotNil(store.shortcutResetError)
    XCTAssertEqual(store.shortcuts.externalBrowserLinkShortcut, .alt)
    XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌘⇧L"))
    try FileManager.default.removeItem(at: file)
    await store.confirmShortcutReset()
    XCTAssertEqual(store.shortcuts.externalBrowserLinkShortcut, .unassigned)
    XCTAssertNil(store.shortcuts.binding("search"))
  }

  func testConfiguredClickRoutesActualMessageLinkExternallyWithoutCreatingTab() throws {
    let store = WorkspaceStore(dataRoot: try root())
    let url = try XCTUnwrap(URL(string: "https://example.invalid/link"))
    store.library.webLinkTarget = .inAppBrowser
    store.draft = "Keep this draft"
    try store.shortcuts.setExternalBrowserLinkShortcut(.primary)
    XCTAssertEqual(store.messageWebLinkBehavior(url, click: nil), .inApp(.split))
    XCTAssertEqual(store.messageWebLinkBehavior(url, click: .init(modifiers: [.command, .shift])), .inApp(.foregroundTab))
    XCTAssertEqual(store.messageWebLinkBehavior(url, click: .init(modifiers: .command)), .external)
    var opened: [URL] = []
    store.openMessageLink(url, project: nil, click: .init(modifiers: .command)) {
      opened.append($0); return true
    }
    XCTAssertEqual(opened, [url])
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertEqual(store.draft, "Keep this draft")
    XCTAssertNil(store.error)
    store.openMessageLink(url, project: nil, click: .init(modifiers: .command), openExternal: { _ in false })
    XCTAssertEqual(store.error, "无法打开此链接。")
    store.library.webLinkTarget = .externalBrowser
    XCTAssertEqual(store.messageWebLinkBehavior(url, click: nil), .external)
    XCTAssertEqual(store.messageWebLinkBehavior(URL(string: "mailto:test@example.invalid")!, click: nil), .external)
  }

  func testFileAndUnsupportedLinksCannotBeForcedIntoExternalBrowser() throws {
    let store = WorkspaceStore(dataRoot: try root())
    try store.shortcuts.setExternalBrowserLinkShortcut(.alt)
    for value in ["javascript:alert(1)", "file:///tmp/file.swift", "../secret.txt"] {
      var opened = false
      store.openMessageLink(try XCTUnwrap(URL(string: value)), project: nil,
        click: .init(modifiers: .option)) { _ in opened = true; return true }
      XCTAssertFalse(opened)
      XCTAssertNotNil(store.error)
    }
  }

  func testTextSearchIncludesDescriptionAndCurrentOptionButKeySearchHidesRow() {
    let editor = ShortcutSettingsState()
    editor.query = "默认浏览器"
    XCTAssertTrue(editor.matchesExternalBrowserShortcut(.unassigned))
    editor.query = "⌥点按"
    XCTAssertTrue(editor.matchesExternalBrowserShortcut(.alt))
    XCTAssertFalse(editor.matchesExternalBrowserShortcut(.primary))
    editor.searchByKeys = true
    XCTAssertFalse(editor.matchesExternalBrowserShortcut(.alt))
    let results = SettingsSearch.results(for: "修饰键")
    XCTAssertTrue(results.contains { $0.field == .shortcutExternalBrowser })
  }
}
