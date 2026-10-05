import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SubagentComposerTests: XCTestCase {
  private func editor(_ view: some View) throws -> (NSWindow, ComposerNativeTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 440, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host; host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
    XCTAssertTrue(window.makeFirstResponder(editor))
    editor.setSelectedRange(.init(location: (editor.string as NSString).length, length: 0))
    return (window, editor)
  }
  private func key(_ code: UInt16 = 36, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: code == 126 ? "" : "\r",
      charactersIgnoringModifiers: code == 126 ? "" : "\r", isARepeat: false, keyCode: code))
  }
  private func view(text: Binding<String>, shortcut: ComposerSendShortcut, sending: Bool = false,
    stopping: Bool = false, canSend: Bool = true, previous: String? = nil, send: @escaping () -> Void) -> some View {
    SubagentComposerView(text: text, plainTextMode: true, sendShortcut: shortcut,
      working: true, sending: sending, stopping: stopping, canSend: canSend, canStop: true,
      stopError: nil, previousPrompt: previous, send: send, stop: {})
  }
  func testNativeReturnMatchesAllThreeSettingsAndModifiedReturnKeepsMultiline() throws {
    let cases: [(ComposerSendShortcut, String, NSEvent.ModifierFlags, Bool)] = [
      (.enter, "one", [], true), (.enter, "one", .shift, false),
      (.commandEnter, "one", [], false), (.commandEnter, "one", .command, true),
      (.commandEnterForMultiline, "one", [], true),
      (.commandEnterForMultiline, "one\ntwo", [], false),
      (.commandEnterForMultiline, "one\ntwo", .command, true),
      (.enter, "one", [.command, .shift], false)]
    for (shortcut, source, modifiers, sends) in cases {
      var text = source, sent = 0
      let (window, editor) = try editor(view(text: .init(get: { text }, set: { text = $0 }),
        shortcut: shortcut, send: { sent += 1 }))
      defer { window.close() }
      editor.keyDown(with: try key(modifiers: modifiers))
      XCTAssertEqual(sent, sends ? 1 : 0, "\(shortcut) \(modifiers)")
      if sends { XCTAssertEqual(editor.string, source) }
      else if modifiers == [.command, .shift] { XCTAssertEqual(editor.string, source) }
      else { XCTAssertTrue(editor.string.contains("\n"), "Native Return must remain available for multiline editing: \(shortcut) \(modifiers)") }
    }
  }
  func testBusyAndUnavailableSendCannotSubmitAndMarkedTextStaysInNativeEditor() throws {
    for (sending, stopping, allowed) in [(true, false, true), (false, true, true), (false, false, false)] {
      var text = "Keep this draft", sent = 0
      let (window, editor) = try editor(view(text: .init(get: { text }, set: { text = $0 }),
        shortcut: .commandEnter, sending: sending, stopping: stopping, canSend: allowed, send: { sent += 1 }))
      defer { window.close() }
      editor.keyDown(with: try key(modifiers: .command))
      XCTAssertEqual(sent, 0); XCTAssertEqual(text, "Keep this draft")
    }
    var text = "", sent = 0
    let (window, editor) = try editor(view(text: .init(get: { text }, set: { text = $0 }), shortcut: .enter, send: { sent += 1 }))
    defer { window.close() }
    editor.setMarkedText("拼音", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    editor.keyDown(with: try key())
    XCTAssertEqual(sent, 0, "An IME confirmation is not a send action")
  }
  func testUpRestoresOnlyThisChildPromptWhenDraftIsEmpty() throws {
    var text = "", sent = 0
    let (window, editor) = try editor(view(text: .init(get: { text }, set: { text = $0 }),
      shortcut: .commandEnter, previous: "Child's previous prompt", send: { sent += 1 }))
    defer { window.close() }
    editor.keyDown(with: try key(126))
    XCTAssertEqual(text, "Child's previous prompt"); XCTAssertEqual(sent, 0)
  }
}
