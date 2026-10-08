import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsPopupFocusTimingTests: XCTestCase {
  func testPinnedPublicCloseCallbacksRestoreUnlessOutsideOrPrevented() throws {
    struct Reference: Decodable {
      struct Item: Decodable { let id: String, focusCalls: Int, defaultPrevented: Bool }
      let sourceSHA256: String, deferredUnmountPresent: Bool, cases: [Item]
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "popup_close_focus_reference_674", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.sourceSHA256, "eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab")
    XCTAssertTrue(reference.deferredUnmountPresent, "The callback fixture does not simulate the reference's deferred unmount")
    XCTAssertEqual(Dictionary(uniqueKeysWithValues: reference.cases.map { ($0.id, $0.focusCalls) }), [
      "modal-close": 1, "nonmodal-close": 1, "nonmodal-outside-left": 0,
      "modal-outside-right": 0, "modal-outside-control-left": 0, "prevented-close": 0])
    XCTAssertTrue(reference.cases.allSatisfy(\.defaultPrevented))
  }

  func testEscapeRestoresTheTriggerBeforeAnImmediateTabAndDoesNotStealItBack() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.owner.toggle(f.button, keyboard: true)
    let popup = try XCTUnwrap(f.owner.popup)
    XCTAssertTrue(f.window.makeFirstResponder(popup))
    XCTAssertTrue(f.owner.handle(try key(53, in: f.window), button: f.button))
    XCTAssertTrue(f.window.firstResponder === f.button, "Escape must finish restoring before the next event")
    f.window.selectNextKeyView(f.button)
    let editor = try XCTUnwrap(f.next.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 1, length: 2))
    try await settle(f.content)
    XCTAssertTrue(f.window.firstResponder === editor)
    XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 2))
  }

  func testSuccessfulSelectionRestoresBeforeImmediateBackwardNavigation() async throws {
    for keyboard in [false, true] {
      let f = try await fixture(); defer { f.window.close() }
      f.owner.toggle(f.button, keyboard: keyboard)
      XCTAssertTrue(f.window.makeFirstResponder(try XCTUnwrap(f.owner.popup)))
      f.owner.choose("choice", button: f.button)
      XCTAssertEqual(f.menu.selected, "choice")
      XCTAssertTrue(f.window.firstResponder === f.button)
      f.window.selectPreviousKeyView(f.button)
      let editor = try XCTUnwrap(f.previous.currentEditor() as? NSTextView)
      try await settle(f.content)
      XCTAssertTrue(f.window.firstResponder === editor)
    }
  }

  func testExplicitLaterFieldFocusSurvivesCancelWithoutLosingSelection() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.owner.toggle(f.button, keyboard: true)
    f.owner.dismiss(f.button, restore: true)
    XCTAssertTrue(f.window.makeFirstResponder(f.next))
    let editor = try XCTUnwrap(f.next.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 2, length: 1))
    try await settle(f.content)
    XCTAssertTrue(f.window.firstResponder === editor)
    XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 1))
  }

  func testCancelThenReopenDoesNotMoveFocusOutOfTheNewPopup() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.owner.toggle(f.button, keyboard: true)
    f.owner.dismiss(f.button, restore: true)
    f.owner.toggle(f.button, keyboard: true)
    let popup = try XCTUnwrap(f.owner.popup)
    XCTAssertTrue(f.window.makeFirstResponder(popup))
    try await settle(f.content)
    XCTAssertTrue(f.window.firstResponder === popup)
    XCTAssertTrue(f.menu.presented)
  }

  func testNoRestoreAndUnavailableTriggerLeaveTheExistingEditorAlone() async throws {
    let f = try await fixture(); defer { f.window.close() }
    for restore in [false, true] {
      f.button.isEnabled = true; try await settle(f.content)
      f.owner.toggle(f.button, keyboard: true)
      XCTAssertTrue(f.window.makeFirstResponder(f.next))
      let editor = try XCTUnwrap(f.next.currentEditor() as? NSTextView)
      if restore { f.button.isEnabled = false }
      f.owner.dismiss(f.button, restore: restore)
      try await settle(f.content)
      XCTAssertTrue(f.window.firstResponder === editor)
    }
  }

  func testColorPickerEscapeRestoresBeforeImmediateTabWithoutOverridingTheEditor() async throws {
    let (window, content, previous, next) = window(); defer { window.close() }
    let host = NSHostingView(rootView: AppearanceColorInput(value: "#181818", label: "颜色") { _ in true })
    host.frame = .init(x: 20, y: 220, width: 96, height: 28); content.addSubview(host)
    try await settle(content)
    let control = try XCTUnwrap(find(host, AppearanceColorInput.Control.self).first)
    let owner = try XCTUnwrap(control.owner)
    previous.nextKeyView = control.swatch; control.swatch.nextKeyView = next; next.nextKeyView = previous
    owner.toggle(control)
    XCTAssertNotNil(owner.popup)
    XCTAssertTrue(owner.handle(try key(53, in: window), in: control))
    XCTAssertTrue(window.firstResponder === control.swatch)
    window.selectNextKeyView(control.swatch)
    let editor = try XCTUnwrap(next.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 1, length: 1))
    try await settle(content)
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 1))
  }

  private struct Fixture {
    let window: NSWindow, content: NSView, previous: NSTextField, next: NSTextField
    let button: SettingsPopupMenuButton.Control, owner: SettingsPopupMenuButton.Coordinator, menu: Menu
  }
  private func fixture() async throws -> Fixture {
    let (window, content, previous, next) = window(), menu = Menu()
    let host = NSHostingView(rootView: SettingsPopupMenuButton(title: "Menu", label: "菜单", menu: menu, formStyle: .font,
      menuHeight: { 80 }, available: true, open: { _ in menu.presented = true },
      choose: { menu.selected = $0; return true }, content: { _ in AnyView(Text("Choice").frame(width: 180, height: 80)) }))
    host.frame = .init(x: 20, y: 220, width: 176, height: 28); content.addSubview(host)
    try await settle(content)
    let button = try XCTUnwrap(find(host, SettingsPopupMenuButton.Control.self).first), owner = try XCTUnwrap(button.owner)
    previous.nextKeyView = button; button.nextKeyView = next; next.nextKeyView = previous
    return .init(window: window, content: content, previous: previous, next: next, button: button, owner: owner, menu: menu)
  }
  private func window() -> (NSWindow, NSView, NSTextField, NSTextField) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = false
    let content = NSView(frame: window.frame), previous = NSTextField(string: "previous"), next = NSTextField(string: "next field")
    previous.frame = .init(x: 20, y: 270, width: 180, height: 24); next.frame = .init(x: 20, y: 170, width: 180, height: 24)
    content.addSubview(previous); content.addSubview(next); window.contentView = content
    return (window, content, previous, next)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded() }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private final class Menu: SettingsPopupMenuState {
    var presented = false, highlightedID: String? = "choice", selected: String?
    func dismiss() { presented = false }
    func move(_ delta: Int) {}
    func edge(last: Bool) {}
    func type(_ character: String, now: TimeInterval) {}
    func space(now: TimeInterval) -> Bool { true }
  }
}
