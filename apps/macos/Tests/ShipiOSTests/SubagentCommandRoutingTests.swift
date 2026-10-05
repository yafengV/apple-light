import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SubagentCommandRoutingTests: XCTestCase {
  private func host(_ view: some View) throws -> (NSWindow, ComposerNativeTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 440, height: 160),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host; host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
    XCTAssertTrue(window.makeFirstResponder(editor)); return (window, editor)
  }
  func testMenuAndPrimaryOrCustomStopBindingsBelongToFocusedChildEditor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    var draft = "child draft", sent = 0, stopped = 0
    let (childWindow, childEditor) = try host(SubagentComposerView(text: .init(get: { draft }, set: { draft = $0 }),
      plainTextMode: true, sendShortcut: .commandEnter, working: true, sending: false, stopping: false,
      canSend: true, canStop: true, stopError: nil, previousPrompt: nil, send: { sent += 1 }, stop: { stopped += 1 }))
    defer { childWindow.close() }
    let menu = try XCTUnwrap(ComposerCommandContext.focused(in: childWindow))
    XCTAssertTrue(menu.execute("send")); XCTAssertEqual(sent, 1)
    XCTAssertTrue(menu.execute("stop")); XCTAssertEqual(stopped, 1)
    XCTAssertFalse(menu.execute("queue-prompt")); XCTAssertFalse(menu.execute("add-files"))
    XCTAssertTrue(ComposerCommandContext.route(ShortcutBinding("⌘."), shortcuts: shortcuts, in: childWindow))
    XCTAssertEqual(stopped, 2)
    try shortcuts.set(ShortcutBinding("⌘⌥."), for: "stop")
    XCTAssertFalse(ComposerCommandContext.route(ShortcutBinding("⌘."), shortcuts: shortcuts, in: childWindow))
    XCTAssertTrue(ComposerCommandContext.route(ShortcutBinding("⌘⌥."), shortcuts: shortcuts, in: childWindow))
    XCTAssertEqual(stopped, 3)
    let (parentWindow, _) = try host(ComposerTextEditor(text: .constant("parent"), focused: .constant(false),
      plainTextMode: true, placeholder: "Parent", accessibilityLabel: "Parent", focusRequest: UUID(),
      onKey: { _, _, _ in false }, onPasteAttachments: { _ in }))
    defer { parentWindow.close() }
    XCTAssertNil(ComposerCommandContext.focused(in: parentWindow))
    XCTAssertFalse(ComposerCommandContext.route(ShortcutBinding("⌘⌥."), shortcuts: shortcuts, in: parentWindow))
    XCTAssertEqual(stopped, 3)
    XCTAssertTrue(menu.execute("clear-prompt")); XCTAssertEqual(draft, "")
    childEditor.isEditable = false
    XCTAssertNil(ComposerCommandContext.focused(in: childWindow))
  }
  func testUnavailableOwnedBindingsCannotFallThroughAndMarkedTextCannotSend() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    var called = 0
    let context = ComposerCommandContext(enabled: [], perform: { _ in called += 1 })
    let (window, editor) = try host(ComposerTextEditor(text: .constant("child"), focused: .constant(false),
      plainTextMode: true, placeholder: "Child", accessibilityLabel: "Child", focusRequest: UUID(),
      onKey: { _, _, _ in false }, onPasteAttachments: { _ in }, localCommands: context))
    defer { window.close() }
    XCTAssertTrue(ComposerCommandContext.route(ShortcutBinding("⌘."), shortcuts: shortcuts, in: window))
    XCTAssertEqual(called, 0, "Owned disabled Stop must be consumed rather than forwarded to the parent")
    editor.coordinator?.parent.localCommands = .init(enabled: ["send", "steer-prompt", "stop"], perform: { _ in called += 1 })
    editor.setMarkedText("拼音", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    let marked = try XCTUnwrap(ComposerCommandContext.focused(in: window))
    XCTAssertFalse(marked.execute("send")); XCTAssertFalse(marked.execute("steer-prompt"))
    XCTAssertTrue(marked.execute("stop")); XCTAssertEqual(called, 1)
    editor.coordinator?.active = false
    XCTAssertNil(ComposerCommandContext.focused(in: window))
  }

  func testMainWindowRoutesSecondaryBindingsToChildWhileComposing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let stop = ShortcutBinding("⌘⌥."), send = ShortcutBinding("⌘⌥↵")
    try store.shortcuts.replace(nil, with: stop, for: "stop")
    try store.shortcuts.replace(nil, with: send, for: "send")
    var invoked: [String] = []
    let context = ComposerCommandContext(enabled: ["stop", "send"], perform: { invoked.append($0) })
    let (window, editor) = try host(ComposerTextEditor(text: .constant("child"), focused: .constant(false),
      plainTextMode: true, placeholder: "Child", accessibilityLabel: "Child", focusRequest: UUID(),
      onKey: { _, _, _ in false }, onPasteAttachments: { _ in }, localCommands: context))
    defer { window.close() }
    editor.setMarkedText("拼音", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertTrue(store.handleWorkspaceShortcut(stop, in: window))
    XCTAssertEqual(invoked, ["stop"])
    XCTAssertTrue(store.handleWorkspaceShortcut(send, in: window))
    XCTAssertEqual(invoked, ["stop"], "Composing Send is consumed without sending either task")
    for overlay in WorkspaceOverlay.allCases {
      store.presentedOverlay = overlay
      XCTAssertFalse(store.handleWorkspaceShortcut(stop, in: window))
    }
    XCTAssertEqual(invoked, ["stop"])
  }
}
