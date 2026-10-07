import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceFontSizePointerTests: XCTestCase {
  func testRealMouseReleaseCommitsBeforeBlurAndOnlyOnce() async throws {
    let state = PointerState(), (window, host, field) = try await host(state)
    defer { window.close() }
    let editor = try begin(field, in: window)
    field.beginArrowHold(direction: 1)
    XCTAssertEqual(editor.string, "15"); XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(state.value, 15, "The arrow release must save without requiring blur")
    XCTAssertEqual(state.writes, 1); XCTAssertNil(field.arrowDirection)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(state.writes, 1)
    window.makeFirstResponder(nil)
    XCTAssertEqual(state.writes, 1)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }

  func testNativeReleaseMatchesEighteenCurrentReferenceCallbackCases() async throws {
    struct Phase: Decodable { let text: String; let writes: [Double] }
    struct Sample: Decodable {
      let kind: AppearanceFontSize; let current: Double; let before: String; let after: String
      let afterRelease: Phase; let afterDuplicateRelease: Phase
    }
    struct Reference: Decodable { let version: String; let sourceSHA256: String; let cases: [Sample] }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_font_size_pointer_reference_648", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.version, "26.930.51102")
    XCTAssertEqual(reference.sourceSHA256, "91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535")
    XCTAssertEqual(reference.cases.count, 18)
    for sample in reference.cases {
      let state = PointerState(); state.value = sample.current; state.kind = sample.kind
      let (window, host, field) = try await host(state); defer { window.close() }
      let editor = try begin(field, in: window)
      editor.string = sample.before; field.stringValue = sample.before
      field.beginArrowHold(direction: 1)
      editor.string = sample.after; field.stringValue = sample.after
      field.mouseUp(with: try mouseRelease(field, in: window))
      XCTAssertEqual(editor.string, sample.afterRelease.text, sample.kind.rawValue + "/" + sample.before)
      XCTAssertEqual(state.saved, sample.afterRelease.writes)
      field.mouseUp(with: try mouseRelease(field, in: window))
      XCTAssertEqual(editor.string, sample.afterDuplicateRelease.text)
      XCTAssertEqual(state.saved, sample.afterDuplicateRelease.writes)
      try await settle(host); XCTAssertFalse(window.isVisible)
    }
  }

  func testVisualTopIncrementsAndBottomDecrementsForBothFontKinds() async throws {
    for kind in AppearanceFontSize.allCases {
      for direction in [-1, 1] {
        let state = PointerState(); state.kind = kind; state.value = kind.defaultValue
        let (window, host, field) = try await host(state); defer { window.close() }
        field.hovered = true
        field.mouseDown(with: try mouseEvent(.leftMouseDown, field, in: window, direction: direction))
        XCTAssertEqual(field.currentEditor()?.string, AppearanceFontSize.text(kind.defaultValue + Double(direction)))
        XCTAssertEqual(state.writes, 0)
        field.mouseUp(with: try mouseEvent(.leftMouseUp, field, in: window, direction: direction))
        XCTAssertEqual(state.value, kind.defaultValue + Double(direction)); XCTAssertEqual(state.writes, 1)
        try await settle(host)
        let replacement = try XCTUnwrap(find(host))
        XCTAssertFalse(replacement === field); XCTAssertNil(field.window)
        XCTAssertEqual(replacement.stringValue, AppearanceFontSize.text(state.value)); XCTAssertFalse(window.isVisible)
      }
    }
  }

  func testHeldArrowSavesOnlyAtReleaseAndStopsRepeating() async throws {
    let state = PointerState(), (window, host, field) = try await host(state)
    defer { window.close() }
    let editor = try begin(field, in: window)
    field.beginArrowHold(direction: 1)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while editor.string != "16", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(editor.string, "16"); XCTAssertEqual(state.writes, 0)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(state.value, 16); XCTAssertEqual(state.writes, 1); XCTAssertNil(field.arrowDirection)
    try await settle(host)
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(state.value, 16); XCTAssertEqual(state.writes, 1); XCTAssertFalse(window.isVisible)
  }

  func testUnchangedReleasePreservesTypedDraftAtLimitUntilBlur() async throws {
    let state = PointerState(), (window, host, field) = try await host(state)
    defer { window.close() }
    let editor = try begin(field, in: window)
    editor.string = "0016"; field.stringValue = "0016"
    field.owner?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    field.beginArrowHold(direction: 1)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(editor.string, "0016"); XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    window.makeFirstResponder(nil)
    XCTAssertEqual(state.value, 16); XCTAssertEqual(state.writes, 1)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }

  func testCancelledDisabledAndBlockedReleasesCannotWrite() async throws {
    for scenario in ["cancelled", "disabled", "blocked"] {
      let state = PointerState(), (window, host, field) = try await host(state)
      defer { window.close() }
      _ = try begin(field, in: window)
      field.beginArrowHold(direction: 1)
      let event = try mouseRelease(field, in: window)
      let scope = PointerModalScope()
      switch scenario {
      case "cancelled": field.cancelArrowHold()
      case "disabled": field.isEnabled = false
      default: WindowModalInteraction.install(scope, in: window)
      }
      field.mouseUp(with: event)
      XCTAssertEqual(state.writes, 0, scenario); XCTAssertEqual(state.value, 14, scenario)
      XCTAssertNil(field.arrowDirection, scenario)
      WindowModalInteraction.remove(scope, from: window)
      // Do not turn fixture teardown into a later blur write.
      field.owner?.active = false
      try await settle(host); XCTAssertFalse(window.isVisible)
    }
  }

  func testDetachingFocusedFieldBlursOnceAndLateReleaseCannotWriteAgain() async throws {
    let state = PointerState(), (window, host, field) = try await host(state)
    defer { window.close() }
    _ = try begin(field, in: window)
    field.beginArrowHold(direction: 1)
    let event = try mouseRelease(field, in: window)
    field.removeFromSuperview()
    // AppKit legitimately ends editing while the field still belongs to its
    // window. Preserve that blur save; the subsequent old release is inert.
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 1)
    XCTAssertNil(field.window); XCTAssertNil(field.arrowDirection)
    field.mouseUp(with: event)
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 1)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }

  func testRejectedReleaseRestoresDraftAndFocusThenRetrySaves() async throws {
    let state = PointerState(); state.reject = true
    let (window, host, field) = try await host(state); defer { window.close() }
    let editor = try begin(field, in: window)
    field.beginArrowHold(direction: 1)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 1)
    XCTAssertEqual(field.stringValue, "14"); XCTAssertEqual(editor.string, "14")
    XCTAssertTrue(window.firstResponder === editor)
    state.reject = false
    field.beginArrowHold(direction: 1)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 2)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }

  func testAppearanceRowReleasePersistsBeforeBlurAndRestoresWithOtherDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-pointer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["keep"] = "未发送🙂"; store.library.preferredEditor = "xcode"
    let (window, host) = try await makeHost(AnyView(AppearanceFontSizeRow(store: store, kind: .code)))
    defer { window.close() }
    let field = try XCTUnwrap(find(host))
    _ = try begin(field, in: window)
    field.beginArrowHold(direction: 1)
    field.mouseUp(with: try mouseRelease(field, in: window))
    XCTAssertEqual(store.appearance.codeSize, 13)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.appearance?.codeSize, 13)
    XCTAssertEqual(restored.drafts["keep"], "未发送🙂"); XCTAssertEqual(restored.preferredEditor, "xcode")
    try await settle(host); XCTAssertFalse(window.isVisible)
  }

  private func mouseRelease(_ field: NSView, in window: NSWindow) throws -> NSEvent {
    try mouseEvent(.leftMouseUp, field, in: window, direction: 1)
  }
  private func mouseEvent(_ type: NSEvent.EventType, _ field: NSView, in window: NSWindow, direction: Int) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type,
      location: field.convert(.init(x: field.bounds.maxX - 8,
        y: field.bounds.midY + CGFloat(direction * 4) * (field.isFlipped ? -1 : 1)), to: nil),
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
  }
  private func begin(_ field: AppearanceFontSizeInput.Control, in window: NSWindow) throws -> NSTextView {
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    field.owner?.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: field))
    return editor
  }
  private func host(_ state: PointerState) async throws -> (NSWindow, NSHostingView<AnyView>, AppearanceFontSizeInput.Control) {
    let (window, host) = try await makeHost(AnyView(PointerFixture(state: state)))
    return (window, host, try XCTUnwrap(find(host)))
  }
  private func makeHost(_ root: AnyView) async throws -> (NSWindow, NSHostingView<AnyView>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: root); window.contentView = host
    try await settle(host)
    return (window, host)
  }
  private func find(_ view: NSView) -> AppearanceFontSizeInput.Control? {
    (view as? AppearanceFontSizeInput.Control) ?? view.subviews.compactMap(find).first
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
  }
}

@MainActor @Observable private final class PointerState {
  var value = 14.0
  var writes = 0
  var saved: [Double] = []
  var reject = false
  var enabled = true
  var mounted = true
  var kind = AppearanceFontSize.ui
}
private struct PointerFixture: View {
  let state: PointerState
  var body: some View {
    if state.mounted {
      AppearanceFontSizeInput(kind: state.kind, value: Binding(get: { state.value }, set: { value in
        state.writes += 1; state.saved.append(value); if !state.reject { state.value = value }
      })).frame(width: 64, height: 28).id(state.value).disabled(!state.enabled)
    }
  }
}

@MainActor private final class PointerModalScope: WindowModalScope {
  let modalRoot = NSView()
  var modalScopeActive: Bool { true }
}
