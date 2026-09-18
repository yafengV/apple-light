import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsMenuPickerTests: XCTestCase {
  func testHiddenLabelDoesNotConsumeInlineMenuWidthButKeepsAccessibilityName() async throws {
    let state = MenuState()
    state.title = "访问权限：" + String(repeating: "long-host-name.", count: 8)
    state.hideLabel = true
    let (window, host) = makeHost(state)
    defer { window.close() }
    try await settle(host)
    let control = try XCTUnwrap(findControl(host))
    XCTAssertEqual(control.accessibilityLabel(), state.title)
    XCTAssertLessThanOrEqual(host.fittingSize.width, control.intrinsicContentSize.width + 16,
      "Inline menus must not render or reserve space for their accessibility label")
  }

  func testSelectionWritesOnceAndKeepsDuplicateLabelsDistinct() async throws {
    let state = MenuState()
    let (window, host) = makeHost(state)
    defer { window.close() }
    try await settle(host)
    let control = try XCTUnwrap(findControl(host))
    XCTAssertEqual(control.accessibilityLabel(), "菜单")
    XCTAssertEqual(control.numberOfItems, 3)
    XCTAssertEqual(control.indexOfSelectedItem, 0)
    XCTAssertTrue(control.canBecomeKeyView)
    control.selectItem(at: 1)
    control.sendAction(control.action, to: control.target)
    XCTAssertEqual(state.selection, 2)
    XCTAssertEqual(state.writes, 1)
    control.sendAction(control.action, to: control.target)
    XCTAssertEqual(state.writes, 1, "Reselecting the current value must not write it again")
    control.selectItem(at: 2)
    control.sendAction(control.action, to: control.target)
    XCTAssertEqual(state.selection, 2, "A disabled option cannot commit")
  }

  func testExternalSelectionAndOptionChangesDoNotWriteBack() async throws {
    let state = MenuState()
    let (window, host) = makeHost(state)
    defer { window.close() }
    try await settle(host)
    let control = try XCTUnwrap(findControl(host))
    state.selection = 2
    state.options.reverse()
    try await settle(host)
    XCTAssertEqual(control.indexOfSelectedItem, 1)
    state.options.removeAll { $0.value == 1 }
    try await settle(host)
    XCTAssertEqual(control.numberOfItems, 2)
    XCTAssertEqual(control.indexOfSelectedItem, 1)
    XCTAssertEqual(state.writes, 0)
    state.options = []
    try await settle(host)
    XCTAssertFalse(control.isEnabled)
    XCTAssertFalse(control.canBecomeKeyView)
    state.options = [.init(value: 2, title: "恢复后的选项")]
    try await settle(host)
    XCTAssertTrue(control.isEnabled)
    XCTAssertEqual(control.titleOfSelectedItem, "恢复后的选项")
    XCTAssertEqual(state.writes, 0)
  }

  func testDisabledHiddenAndUnmountedMenusCannotActOrTakeFocus() async throws {
    let state = MenuState()
    let (window, host) = makeHost(state)
    defer { window.close() }
    try await settle(host)
    let control = try XCTUnwrap(findControl(host))
    state.enabled = false
    try await settle(host)
    XCTAssertFalse(control.acceptsFirstResponder)
    XCTAssertFalse(control.canBecomeKeyView)
    XCTAssertFalse(control.accessibilityPerformPress())
    control.selectItem(at: 1)
    control.sendAction(control.action, to: control.target)
    XCTAssertEqual(state.writes, 0)
    state.enabled = true
    try await settle(host)
    host.isHidden = true
    XCTAssertFalse(control.acceptsFirstResponder)
    XCTAssertFalse(control.canBecomeKeyView)
    XCTAssertFalse(control.accessibilityPerformPress())
    control.selectItem(at: 1)
    control.sendAction(control.action, to: control.target)
    XCTAssertEqual(state.writes, 0)
    host.isHidden = false
    state.mounted = false
    try await settle(host)
    XCTAssertFalse(control.active)
    XCTAssertNil(control.target)
    XCTAssertFalse(control.acceptsFirstResponder)
    XCTAssertFalse(control.accessibilityPerformPress())
    XCTAssertEqual(state.writes, 0)
  }

  private func makeHost(_ state: MenuState) -> (NSWindow, NSHostingView<MenuFixture>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: MenuFixture(state: state))
    window.contentView = host
    return (window, host)
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
  }

  private func findControl(_ view: NSView) -> SettingsMenuControl? {
    if let control = view as? SettingsMenuControl { return control }
    return view.subviews.lazy.compactMap(findControl).first
  }
}

@Observable private final class MenuState {
  var title = "菜单"
  var hideLabel = false
  var selection = 1
  var writes = 0
  var enabled = true
  var mounted = true
  var options: [SettingsMenuOption<Int>] = [
    .init(value: 1, title: "同名选项"),
    .init(value: 2, title: "同名选项"),
    .init(value: 3, title: "不可用", enabled: false)
  ]
}

private struct MenuFixture: View {
  let state: MenuState
  var body: some View {
    if state.mounted {
      Group {
        if state.hideLabel { menu.labelsHidden() }
        else { menu }
      }.disabled(!state.enabled).fixedSize()
    }
  }

  private var menu: some View {
    SettingsMenuPicker(state.title, selection: Binding(
      get: { state.selection }, set: { state.selection = $0; state.writes += 1 }),
      options: state.options)
  }
}
