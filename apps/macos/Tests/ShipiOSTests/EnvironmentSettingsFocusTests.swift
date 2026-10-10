import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class EnvironmentSettingsFocusTests: XCTestCase {
  func testNativeEnvironmentSaveAndDiscardResumeOverviewKeyboardFocus() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and an actual key window")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.open(project)
    addTeardownBlock { @MainActor in await store.shutdown() }
    XCTAssertTrue(store.connected, store.error ?? "")
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
    func wait(_ condition: () -> Bool) async throws {
      for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(25)); host.layoutSubtreeIfNeeded()
      }
      XCTFail("Expected environment UI did not settle")
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
    func press(_ label: String) throws {
      let button = try XCTUnwrap(element(label, in: host), label)
      XCTAssertEqual(button.accessibilityPerformPress?(), true, label)
    }
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func nameField() -> NSTextField? {
      fields(host).first { $0.accessibilityLabel() == "环境名称" && $0.window === window }
    }
    func editName(_ text: String) async throws {
      let field = try XCTUnwrap(nameField())
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.insertText(text, replacementRange: .init(location: 0, length: editor.string.utf16.count))
      try await settle()
    }
    func post(_ code: UInt16, _ characters: String) throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
      }
    }
    try await settle(); XCTAssertTrue(window.isKeyWindow)
    store.openSettings(.environments); try await settle()
    try press("打开项目环境：Project")
    try await wait { element("创建本地环境", in: host) != nil }
    try press("创建本地环境"); try await settle()
    try await editName("环境保存验收")
    try press("保存共享环境")
    try await wait { store.environmentSettingsSession.exists && element("编辑本地环境", in: host) != nil }
    try await settle()
    XCTAssertEqual(store.environmentSettingsSession.name, "环境保存验收")
    // The source save button has been removed. Enter must reach the overview's
    // edit action without a click or a fresh Tab traversal.
    try post(36, "\r"); try await settle()
    let saved = try XCTUnwrap(nameField(), "Save must return focus to the overview edit action")
    XCTAssertEqual(saved.stringValue, "环境保存验收")
    try await editName("未保存的环境")
    try press("‹ Project"); try await wait { window.attachedSheet != nil }
    try post(53, "\u{1b}"); try await wait { window.attachedSheet == nil }
    try await settle()
    XCTAssertEqual(nameField()?.stringValue, "未保存的环境")
    try press("‹ Project"); try await wait { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet)
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let discard = try XCTUnwrap(buttons(try XCTUnwrap(sheet.contentView))
      .first { $0.title == "放弃修改并继续" })
    XCTAssertTrue(discard.isEnabled)
    XCTAssertTrue(sheet.makeFirstResponder(discard))
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: sheet.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
      NSApp.postEvent(event, atStart: false)
    }
    try await wait { window.attachedSheet == nil && element("编辑本地环境", in: host) != nil }
    try await settle()
    XCTAssertEqual(store.environmentSettingsSession.name, "环境保存验收")
    try post(36, "\r"); try await settle()
    XCTAssertEqual(nameField()?.stringValue, "环境保存验收", "Discard must resume the overview edit action")
    // Returning from a clean editor restores Edit; returning from the overview
    // restores the same project entry rather than a dead root responder.
    try post(36, "\r"); try await settle()
    try await wait { element("编辑本地环境", in: host) != nil }
    try press("‹ 环境"); try await settle()
    try post(36, "\r"); try await settle()
    try await wait { element("编辑本地环境", in: host) != nil }
    try post(36, "\r"); try await settle()
    XCTAssertEqual(nameField()?.stringValue, "环境保存验收")
  }
}
