import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsFocusRevealTests: XCTestCase {
  func testAcceptedNativeFocusRevealsFieldsMenuAndEditorWithoutChangingValues() async throws {
    for kind in RevealControlKind.allCases {
      let fixture = RevealFixtureState(kind: kind)
      let (window, host) = makeHost(fixture)
      defer { window.close() }
      try await settle(host)
      XCTAssertFalse(fixture.probe.bounds.intersects(fixture.probe.visibleRect), "initial \(kind)")
      let anchor = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Before form" })
      XCTAssertTrue(window.makeFirstResponder(anchor))
      let target: NSView
      switch kind {
      case .field, .secure: target = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0 !== anchor })
      case .menu: target = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsMenuControl }.first)
      default: target = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsTextEditorContent.TextView }.first)
      }
      XCTAssertTrue(window.makeFirstResponder(target), "actual focus \(kind)")
      try await settle(host)
      XCTAssertTrue(fixture.probe.bounds.intersects(fixture.probe.visibleRect), "Focused \(kind) must become visible")
      XCTAssertEqual(fixture.text, "中文 settings draft")
      XCTAssertEqual(fixture.selection, 0)
      if kind == .menu || kind == .editor { XCTAssertEqual(fixture.writes, 0, "Focusing \(kind) must not activate it") }
      XCTAssertGreaterThanOrEqual(fixture.probe.bounds.intersection(fixture.probe.visibleRect).height,
        fixture.probe.bounds.height - 1, "Show all of \(kind), not just an edge")
    }
  }

  func testFocusedTextFieldRetainsSelectionAndAllowsScrollingAwayAcrossUpdates() async throws {
    let fixture = RevealFixtureState(kind: .field)
    let (window, host) = makeHost(fixture); defer { window.close() }
    try await settle(host)
    let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }
      .first { $0.accessibilityLabel() != "Before form" })
    XCTAssertTrue(window.makeFirstResponder(field)); try await settle(host)
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 1, length: 4))
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
      .first { ($0.documentView?.frame.height ?? 0) > 700 })
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    try await settle(host)
    XCTAssertFalse(fixture.probe.bounds.intersects(fixture.probe.visibleRect))
    fixture.tick += 1
    try await settle(host)
    XCTAssertFalse(fixture.probe.bounds.intersects(fixture.probe.visibleRect),
      "An unrelated render must not keep dragging the viewport back to the focused field")
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 4))
    XCTAssertEqual(fixture.text, "中文 settings draft")
  }

  func testNativeFocusCallbacksRejectLostHiddenDisabledAndDismantledSources() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let menu = SettingsMenuControl(frame: .init(x: 10, y: 10, width: 150, height: 28))
    let editor = SettingsTextEditorContent.TextView(frame: .init(x: 10, y: 50, width: 300, height: 60))
    window.contentView?.addSubview(menu); window.contentView?.addSubview(editor)
    var calls = 0
    menu.didFocus = { calls += 1 }; editor.didFocus = { calls += 1 }
    for target in [menu as NSView, editor] {
      XCTAssertTrue(window.makeFirstResponder(target)); window.makeFirstResponder(nil)
      try await settle(target); XCTAssertEqual(calls, 0, "Lost focus")
      XCTAssertTrue(window.makeFirstResponder(target)); target.isHidden = true
      try await settle(target); XCTAssertEqual(calls, 0, "Hidden source")
      window.makeFirstResponder(nil); target.isHidden = false
    }
    XCTAssertTrue(window.makeFirstResponder(menu)); menu.isEnabled = false
    try await settle(menu); XCTAssertEqual(calls, 0)
    menu.isEnabled = true; try await settle(menu)
    XCTAssertTrue(window.makeFirstResponder(editor)); editor.setEnabled(false)
    try await settle(editor); XCTAssertEqual(calls, 0)
    editor.setEnabled(true)
    XCTAssertTrue(window.makeFirstResponder(menu)); menu.active = false; menu.didFocus = nil
    try await settle(menu); XCTAssertEqual(calls, 0)
    XCTAssertTrue(window.makeFirstResponder(editor)); editor.didFocus = nil
    try await settle(editor); XCTAssertEqual(calls, 0)
    editor.didFocus = { calls += 1 }
    window.makeFirstResponder(nil); XCTAssertTrue(window.makeFirstResponder(editor))
    try await settle(editor); XCTAssertEqual(calls, 1, "An accepted current editor reports focus")
  }

  private func makeHost(_ state: RevealFixtureState) -> (NSWindow, NSHostingView<RevealFixture>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 240),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RevealFixture(state: state))
    window.contentView = host
    return (window, host)
  }
  private func settle(_ view: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private enum RevealControlKind: String, CaseIterable { case field, secure, menu, editor }
@MainActor @Observable private final class RevealFixtureState {
  let kind: RevealControlKind
  let probe = NSView()
  var text = "中文 settings draft"
  var selection = 0
  var writes = 0
  var tick = 0
  init(kind: RevealControlKind) { self.kind = kind }
}
private struct RevealFixture: View {
  let state: RevealFixtureState
  var body: some View {
    VStack {
      RevealAnchor().frame(height: 24)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            Color.clear.frame(height: 700)
            control.background(RevealProbe(view: state.probe))
            Color.clear.frame(height: 100)
            Text("Update \(state.tick)")
          }.padding(20)
        }.environment(\.settingsRevealFocusedControl, { proxy.scrollTo($0) })
      }
    }
  }
  @ViewBuilder private var control: some View {
    switch state.kind {
    case .field: SettingsTextField("Target field", text: Binding(get: { state.text }, set: { state.text = $0; state.writes += 1 }))
    case .secure: SettingsSecureField("Target secure", text: Binding(get: { state.text }, set: { state.text = $0; state.writes += 1 }))
    case .menu: SettingsMenuPicker("Target menu", selection: Binding(get: { state.selection }, set: { state.selection = $0; state.writes += 1 }), options: [.init(value: 0, title: "First"), .init(value: 1, title: "Second")])
    case .editor: SettingsTextEditor(text: Binding(get: { state.text }, set: { state.text = $0; state.writes += 1 }), label: "Target editor").frame(height: 80)
    }
  }
}
private struct RevealProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ view: NSView, context: Context) {}
}
private struct RevealAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(); field.stringValue = "anchor"; field.setAccessibilityLabel("Before form")
    return field
  }
  func updateNSView(_ view: NSTextField, context: Context) {}
}
