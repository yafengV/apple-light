import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class ShortcutSettingsStateTests: XCTestCase {
  private func event(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code))
  }
  @MainActor func testConflictStaysInlineThenValidBindingSavesAndSameValueIsNoOp() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = ShortcutPreferences(file: root.appendingPathComponent("keys.json"))
    let state = ShortcutSettingsState()
    state.begin("search", replacing: nil)
    let id = try XCTUnwrap(state.capture?.id)
    state.receive(try event(40, characters: "k", flags: .command), sessionID: id, preferences: preferences)
    XCTAssertNotNil(state.capture?.warning)
    XCTAssertTrue(preferences.overrides.isEmpty)
    state.receive(try event(37, characters: "L", flags: [.command, .shift]), sessionID: id, preferences: preferences)
    XCTAssertNil(state.capture)
    XCTAssertEqual(preferences.binding("search"), ShortcutBinding("⌘⇧L"))
    state.begin("palette", replacing: ShortcutBinding("⌘K"))
    state.receive(try event(40, characters: "k", flags: .command), sessionID: try XCTUnwrap(state.capture?.id), preferences: preferences)
    XCTAssertNil(state.capture)
    XCTAssertNil(preferences.overrides["palette"], "Recording the existing binding must not create an override")
  }

  @MainActor func testOldBlurCannotCancelNewRowAndEscapeNeverAssignsItself() throws {
    let preferences = ShortcutPreferences(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let state = ShortcutSettingsState()
    state.begin("search", replacing: nil)
    let first = try XCTUnwrap(state.capture?.id)
    state.begin("approval-decline", replacing: ShortcutBinding("⎋"))
    let second = try XCTUnwrap(state.capture?.id)
    state.cancel(first)
    XCTAssertEqual(state.capture?.id, second)
    state.receive(try event(40, characters: "k", flags: .command, repeated: true), sessionID: second, preferences: preferences)
    XCTAssertNil(state.capture?.warning)
    state.receive(try event(53), sessionID: second, preferences: preferences)
    XCTAssertNil(state.capture)
    XCTAssertTrue(preferences.overrides.isEmpty)
  }

  @MainActor func testKeystrokeSearchStaysActiveReplacesQueryAndEscapeReturnsToText() throws {
    let state = ShortcutSettingsState()
    state.query = "old filter"
    state.toggleSearchMode()
    XCTAssertTrue(state.searchByKeys)
    XCTAssertTrue(state.query.isEmpty)
    state.receiveSearch(try event(40, characters: "k", flags: .command))
    XCTAssertEqual(state.query, "⌘K")
    state.receiveSearch(try event(37, characters: "l", flags: .command, repeated: true))
    XCTAssertEqual(state.query, "⌘K")
    state.receiveSearch(try event(37, characters: "l", flags: .command))
    XCTAssertEqual(state.query, "⌘L")
    XCTAssertTrue(state.searchByKeys)
    state.receiveSearch(try event(53))
    XCTAssertFalse(state.searchByKeys)
    XCTAssertTrue(state.query.isEmpty)
  }

  @MainActor func testFocusedRecorderReleasesCaptureOnBlurAndTeardownExactlyOnce() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = ShortcutCapture.Field()
    window.contentView = field
    var activity: [Bool] = []
    var blurCount = 0
    field.activityChanged = { activity.append($0) }
    field.onBlur = { blurCount += 1 }
    field.install()
    XCTAssertTrue(activity.isEmpty, "Mounted but unfocused controls must not disable application shortcuts")
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertEqual(activity, [true])
    XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertEqual(activity, [true, false])
    XCTAssertEqual(blurCount, 1)
    XCTAssertTrue(window.makeFirstResponder(field))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertEqual(activity, [true, false, true, false], "Changing active windows must release global capture guards")
    XCTAssertEqual(blurCount, 2)
    XCTAssertTrue(window.makeFirstResponder(field))
    field.stop(); field.stop()
    XCTAssertEqual(activity, [true, false, true, false, true, false])
    XCTAssertEqual(blurCount, 2)
  }

  @MainActor func testResetFailureRetainsModalAndBindingsThenRetrySucceeds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let file = root.appendingPathComponent("keys.json")
    store.shortcuts = ShortcutPreferences(file: file)
    try store.shortcuts.set(ShortcutBinding("⌘⇧L"), for: "search")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    store.openSettings(.shortcuts)
    store.requestShortcutReset()
    XCTAssertTrue(store.hasSettingsConfirmation)
    XCTAssertFalse(store.commandEnabled("new"))
    store.requestArchiveDeletion(.all, ids: ["other"])
    XCTAssertNil(store.archiveDeletion)
    await store.confirmShortcutReset()
    XCTAssertTrue(store.shortcutResetRequested)
    XCTAssertNotNil(store.shortcutResetError)
    XCTAssertEqual(store.shortcuts.binding("search"), ShortcutBinding("⌘⇧L"))
    XCTAssertFalse(store.resettingShortcuts)
    store.resettingShortcuts = true
    store.dismissShortcutReset()
    XCTAssertTrue(store.shortcutResetRequested)
    store.resettingShortcuts = false
    try FileManager.default.removeItem(at: file)
    await store.confirmShortcutReset()
    XCTAssertFalse(store.hasSettingsConfirmation)
    XCTAssertNil(store.shortcutResetError)
    XCTAssertTrue(store.shortcuts.overrides.isEmpty)
  }

  @MainActor func testRowEditorRendersAtCommandWithoutAdditionalScrollContainer() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.openSettings(.shortcuts)
    let editor = ShortcutSettingsState()
    let command = try XCTUnwrap(DesktopCommand.all.first)
    editor.begin(command.id, replacing: store.shortcuts.binding(command.id))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ShortcutSettingsView(store: store, editor: editor))
    window.contentView = host
    for width in [700.0, 400.0] {
      if width == 400 { editor.capture?.warning = "已用于“命令菜单”" }
      window.setContentSize(NSSize(width: width, height: 500)); host.frame.size = NSSize(width: width, height: 500)
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      let views = descendants(host)
      XCTAssertEqual(views.compactMap { $0 as? NSScrollView }.count, 1)
      XCTAssertEqual(views.compactMap { $0 as? ShortcutCapture.Field }.count, 1)
      let field = try XCTUnwrap(views.compactMap { $0 as? ShortcutCapture.Field }.first)
      let rect = host.convert(field.bounds, from: field)
      XCTAssertGreaterThan(rect.minY, 80, "Capture belongs to the command row below the sticky search controls")
      XCTAssertLessThanOrEqual(rect.maxX, width)
      if width == 400 {
        XCTAssertEqual(rect.minX, 24, accuracy: 1, "The compact control must align with the page inset")
        XCTAssertGreaterThan(rect.minY, 180, "The command title must occupy its own line above capture")
      }
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: root.appendingPathComponent("shortcut-inline-\(Int(width)).png"))
      }
    }
  }
}
