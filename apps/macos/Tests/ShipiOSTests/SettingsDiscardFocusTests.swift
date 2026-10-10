import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsDiscardFocusTests: XCTestCase {
  func testNativeSearchTabThenImmediateActivationKeepsNavigationOrder() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and an actual key window")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root, agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    XCTAssertFalse(store.libraryRecoveryBlocksInteraction)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 750),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.identifier = .init("main")
    let host = NSHostingView(rootView: AppContentView(store: store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
    }
    func post(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
      }
    }
    func fields(_ view: NSView) -> [NSSearchField] {
      (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    try await settle()
    XCTAssertTrue(window.isKeyWindow)
    store.openSettings(.model); try await settle()
    let search = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "搜索设置" })
    for text in ["", "菜单栏"] {
      store.requestSettingsPage(.model); try await settle()
      XCTAssertTrue(window.makeFirstResponder(search))
      let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
      editor.insertText(text, replacementRange: .init(location: 0, length: editor.string.utf16.count))
      try await settle()
      let before = store.settingsSearchRequest?.token
      // Deliver both keys without an intervening render/layout or task yield.
      try post(48, "\t"); try post(36, "\r")
      try await settle()
      XCTAssertEqual(store.settingsPage, .general, "query=\(text)")
      if !text.isEmpty {
        XCTAssertEqual(store.settingsSearchRequest?.result.field, .menuBar)
        XCTAssertNotEqual(store.settingsSearchRequest?.token, before)
      }
    }
    store.requestSettingsPage(.model); try await settle()
    XCTAssertTrue(window.makeFirstResponder(search))
    try post(48, "\u{19}", flags: .shift); try post(36, "\r")
    try await settle()
    XCTAssertEqual(store.destination, .workspace, "Immediate Shift-Tab→Enter must activate Back")
    await store.shutdown()
  }

  func testNativeCancelledSettingsExitRestoresSearchAndBackKeyboardFocus() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and an actual key window")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root, agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    XCTAssertFalse(store.libraryRecoveryBlocksInteraction, "The real settings root requires a restored workspace")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 750),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.identifier = .init("main")
    let host = NSHostingView(rootView: AppContentView(store: store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
    }
    func post(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
      }
    }
    func fields(_ view: NSView) -> [NSSearchField] {
      (view as? NSSearchField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func element(_ label: String, in object: Any) -> AnyObject? {
      guard let node = object as? NSObject else { return nil }
      let dynamic: AnyObject = node
      if dynamic.accessibilityLabel?() == label { return dynamic }
      for child in dynamic.accessibilityChildren?() ?? [] {
        if let found = element(label, in: child) { return found }
      }
      return nil
    }
    try await settle()
    XCTAssertTrue(window.isKeyWindow)
    // Follow the product interaction: activate the main window, then open settings.
    store.openSettings(.model)
    try await settle()
    let search = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "搜索设置" })
    XCTAssertTrue(search.window === window)
    XCTAssertTrue(window.makeFirstResponder(search), "Establish actual native search focus before testing its return")
    try await settle()
    func query(_ text: String) async throws {
      XCTAssertTrue(window.makeFirstResponder(search))
      let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
      editor.insertText(text, replacementRange: .init(location: 0, length: editor.string.utf16.count))
      try await settle()
    }
    XCTAssertTrue(window.firstResponder === search.currentEditor())
    let queryEditor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    queryEditor.insertText("模型", replacementRange: .init(location: 0, length: 0))
    try await settle()
    let selection = NSRange(location: 1, length: 1)
    queryEditor.setSelectedRange(selection)
    store.modelSettingsDirty = true
    store.closeSettings()
    try await settle()
    XCTAssertEqual(store.pendingSettingsNavigation, .close)
    try post(53, "\u{1b}"); try await settle()
    XCTAssertNil(store.pendingSettingsNavigation)
    XCTAssertTrue(store.modelSettingsDirty)
    XCTAssertTrue(window.firstResponder === search.currentEditor(), "Cancellation must resume the native search editor")
    XCTAssertEqual(search.stringValue, "模型")
    XCTAssertEqual((search.currentEditor() as? NSTextView)?.selectedRange(), selection)

    // Traverse to Back through the actual native search editor. Its Enter action
    // must work again after cancellation without another click or Tab.
    window.makeFirstResponder(search)
    try post(48, "\u{19}", flags: .shift); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertEqual(store.pendingSettingsNavigation, .close)
    try post(13, "w", flags: .command); try await settle()
    XCTAssertNil(store.pendingSettingsNavigation)
    XCTAssertEqual(store.destination, .settings)
    try post(36, "\r"); try await settle()
    XCTAssertEqual(store.pendingSettingsNavigation, .close, "Back must recover its own SwiftUI keyboard focus")
    store.cancelDiscardSettingsChanges(); try await settle()

    try await query("")
    let general = try XCTUnwrap(element("通用", in: host))
    XCTAssertEqual(general.accessibilityPerformPress?(), true)
    try await settle()
    XCTAssertEqual(store.pendingSettingsNavigation, .page(.general))
    try post(53, "\u{1b}"); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertEqual(store.pendingSettingsNavigation, .page(.general), "Cancellation resumes the originating page button")
    try post(48, "\t"); try post(36, "\r"); try await settle()
    XCTAssertEqual(store.settingsPage, .general)
    try post(48, "\t"); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertEqual(store.settingsPage, .notifications, "Discarding must resume keyboard traversal on the new page")

    store.openSettings(.model); try await settle()
    store.modelSettingsDirty = true
    try await query("菜单栏")
    try post(125, "\u{f701}"); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertNotNil(store.pendingSettingsNavigation)
    try post(53, "\u{1b}"); try await settle()
    XCTAssertTrue(window.firstResponder === search.currentEditor())
    XCTAssertEqual(search.stringValue, "菜单栏")
    let result = try XCTUnwrap(element("通用：在菜单栏中显示", in: host))
    XCTAssertEqual(result.accessibilityPerformPress?(), true)
    try await settle()
    XCTAssertNotNil(store.pendingSettingsNavigation)
    try post(53, "\u{1b}"); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertNotNil(store.pendingSettingsNavigation, "Cancellation resumes the originating search-result button")
    try post(48, "\t"); try post(36, "\r"); try await settle()
    XCTAssertEqual(store.settingsPage, .general)
    let previousReveal = store.settingsSearchRequest?.token
    try post(36, "\r"); try await settle()
    XCTAssertNotEqual(store.settingsSearchRequest?.token, previousReveal, "Confirmed search navigation resumes the result button")

    store.openSettings(.model); try await settle()
    store.modelSettingsDirty = true
    try await query("菜单栏")
    try post(125, "\u{f701}"); try await settle()
    try post(36, "\r"); try await settle()
    XCTAssertNotNil(store.pendingSettingsNavigation)
    try post(48, "\t"); try post(36, "\r"); try await settle()
    XCTAssertEqual(store.settingsPage, .general)
    let confirmedEditor = try XCTUnwrap(search.currentEditor(), "Confirmed navigation must own a live native query editor")
    XCTAssertTrue(window.firstResponder === confirmedEditor, "Confirmed native search navigation resumes the query editor")

    // A dismissed request cannot reclaim focus after another navigation or modal.
    var restored = 0
    for change in ["page", "destination", "confirmation", "newRequest", "window"] {
      store.openSettings(.model); try await settle()
      store.modelSettingsDirty = true
      store.closeSettings(onCancelFocus: { restored += 1 })
      try await settle()
      store.cancelDiscardSettingsChanges()
      var otherWindow: NSWindow?
      switch change {
      case "page": store.settingsPage = .general
      case "destination":
        store.destination = .workspace; store.openSettings(.model)
      case "confirmation": store.shortcutResetRequested = true
      case "newRequest": store.closeSettings()
      default:
        let other = NSWindow(contentRect: .init(x: 30, y: 30, width: 200, height: 150),
          styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil); otherWindow = other
      }
      try await settle()
      XCTAssertEqual(restored, 0, change)
      if let otherWindow {
        XCTAssertTrue(otherWindow.isKeyWindow)
        otherWindow.close(); window.makeKeyAndOrderFront(nil)
      }
      store.shortcutResetRequested = false
      if store.pendingSettingsNavigation != nil { store.confirmDiscardSettingsChanges() }
      try await settle()
    }
    store.openSettings(.model); try await settle()
    store.modelSettingsDirty = true
    store.closeSettings(onCancelFocus: { restored += 1 }); try await settle()
    store.confirmDiscardSettingsChanges()
    try await settle()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertFalse(window.firstResponder === search.currentEditor())
    XCTAssertEqual(restored, 0, "Discarding and exiting must leave focus to the destination")
    XCTAssertTrue(window.isVisible)
    await store.shutdown()
  }
}
