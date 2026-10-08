import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceDictionaryInteractionTests: XCTestCase {
  func testActualReferenceCallbackTraceMatchesDraftAndNormalizationContracts() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "voice_dictionary_reference_678", withExtension: "json", subdirectory: "Fixtures"))
    let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let enter = try XCTUnwrap(data["afterEnter"] as? [String: Any])
    XCTAssertEqual(enter["saved"] as? [String], ["First", "Last"])
    XCTAssertEqual(enter["values"] as? [String], ["  中文草稿  ", "", "Last"])
    XCTAssertEqual(enter["focused"] as? Int, 1)
    let blur = try XCTUnwrap(data["afterRealBlur"] as? [String: Any])
    XCTAssertEqual(blur["saved"] as? [String], ["中文草稿", "Last"])
    let remove = try XCTUnwrap(data["afterRemove"] as? [String: Any])
    XCTAssertEqual(remove["saved"] as? [String], ["First edited", "Last"])
    XCTAssertEqual(remove["prevented"] as? Bool, true)
    let empty = try XCTUnwrap(data["empty"] as? [String: Any])
    XCTAssertEqual(empty["disabled"] as? Bool, true)
    XCTAssertEqual(empty["placeholder"] as? String, "Jane Doe")
    let normalization = try XCTUnwrap(data["normalization"] as? [[String: String]])
    for value in normalization {
      let input = try XCTUnwrap(value["input"]), output = try XCTUnwrap(value["output"])
      XCTAssertEqual(VoicePreferences(dictationDictionary: [input]).dictationDictionary,
        output.isEmpty ? [] : [output], "Input: \(input.unicodeScalars.map(\.value))")
    }
  }

  func testPointerRemovePreservesEditingOnDownThenSavesCurrentDraftAndRemovesCorrectIndex() async throws {
    try await withCard(["First", "Middle", "Last"]) { store, window, host in
      let originals = self.fields(host)
      let first = try XCTUnwrap(originals.first)
      XCTAssertTrue(window.makeFirstResponder(first))
      let editor = try XCTUnwrap(first.currentEditor() as? NSTextView)
      editor.string = "  First edited  "
      first.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
      editor.setSelectedRange(.init(location: 3, length: 4)); try await self.settle(host)
      let remove = try self.button("voice-dictionary-remove-1", in: host)
      try self.mouse(.leftMouseDown, on: remove, window: window); try await self.settle(host)
      XCTAssertTrue(first.currentEditor() === editor); XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.selectedRange(), .init(location: 3, length: 4))
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["First", "Middle", "Last"])
      try self.mouse(.leftMouseUp, on: remove, window: window); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["First edited", "Last"])
      XCTAssertEqual(self.fields(host).map(\.stringValue), ["First edited", "Last"])
      XCTAssertTrue(self.fields(host)[0] === originals[0]); XCTAssertTrue(self.fields(host)[1] === originals[1])
      XCTAssertTrue(window.firstResponder === editor)
      let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")))
      XCTAssertEqual(restored.voicePreferences.dictationDictionary, ["First edited", "Last"])
    }
  }

  func testTabCommitsDraftAndFocusesRemoveWithReleaseActivation() async throws {
    try await withCard(["Before", "Last"]) { store, window, host in
      let field = try XCTUnwrap(self.fields(host).first)
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.string = "  After  "
      field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
      try await self.settle(host)
      try self.key(.keyDown, code: 48, text: "\t", window: window); try await self.settle(host)
      let remove = try self.button("voice-dictionary-remove-0", in: host)
      XCTAssertTrue(window.firstResponder === remove)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["After", "Last"])
      XCTAssertTrue(self.fields(host)[0] === field)
      try self.key(.keyDown, code: 49, text: " ", window: window); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["After", "Last"])
      try self.key(.keyUp, code: 49, text: " ", window: window); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Last"])
    }
  }

  func testKeyboardAddFocusesNewEntryAndEmptyFallbackDisablesRemoval() async throws {
    try await withCard([]) { store, window, host in
      let remove = try self.button("voice-dictionary-remove-0", in: host)
      XCTAssertFalse(remove.isAccessibilityEnabled()); XCTAssertFalse(remove.accessibilityPerformPress())
      let add = try self.button("voice-dictionary-add", in: host)
      XCTAssertTrue(window.makeFirstResponder(add))
      try self.key(.keyDown, code: 76, text: "\u{3}", window: window); try await self.settle(host)
      XCTAssertEqual(self.fields(host).map(\.stringValue), ["", ""])
      XCTAssertTrue(self.fields(host)[1].currentEditor() === window.firstResponder)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, [])
      XCTAssertEqual(self.fields(host)[0].placeholderString, "Jane Doe")
      XCTAssertEqual(self.fields(host)[1].placeholderString, "Acme Widget")
      window.makeFirstResponder(nil); try await self.settle(host)
      XCTAssertEqual(self.fields(host).map(\.stringValue), [""])
      XCTAssertFalse(try self.button("voice-dictionary-remove-0", in: host).isAccessibilityEnabled())
    }
  }

  func testPendingSpaceCancelsOnFocusAndWindowDeactivationAndDisabledControlsDoNotAct() async throws {
    try await withCard(["One"]) { store, window, host in
      let add = try self.button("voice-dictionary-add", in: host)
      let field = try XCTUnwrap(self.fields(host).first)
      for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
        XCTAssertTrue(window.makeFirstResponder(add))
        try self.key(.keyDown, code: 49, text: " ", window: window)
        NotificationCenter.default.post(name: name, object: name == NSWindow.didResignKeyNotification ? window : NSApp)
        try self.key(.keyUp, code: 49, text: " ", window: window); try await self.settle(host)
        XCTAssertEqual(self.fields(host).map(\.stringValue), ["One"])
      }
      XCTAssertTrue(window.makeFirstResponder(add))
      try self.key(.keyDown, code: 49, text: " ", window: window)
      XCTAssertTrue(window.makeFirstResponder(field))
      try self.key(.keyUp, code: 49, text: " ", window: window); try await self.settle(host)
      XCTAssertEqual(self.fields(host).map(\.stringValue), ["One"])
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["One"])
    }
  }

  func testRemovingFocusedIndexKeepsFieldAndUpdatesEditorThenAllRemovedUsesBlankFallback() async throws {
    try await withCard(["First", "Next"]) { store, window, host in
      let field = try XCTUnwrap(self.fields(host).first)
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      XCTAssertTrue(try self.button("voice-dictionary-remove-0", in: host).accessibilityPerformPress())
      try await self.settle(host)
      XCTAssertTrue(self.fields(host)[0] === field); XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.string, "Next")
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Next"])
      XCTAssertTrue(try self.button("voice-dictionary-remove-0", in: host).accessibilityPerformPress())
      try await self.settle(host)
      XCTAssertEqual(self.fields(host).map(\.stringValue), [""])
      XCTAssertEqual(store.voicePreferences.dictationDictionary, [])
      XCTAssertFalse(try self.button("voice-dictionary-remove-0", in: host).accessibilityPerformPress())
    }
  }

  func testWhitespaceNormalizationKeepsDuplicatesAndTabFocusDoesNotRecreateRows() async throws {
    try await withCard(["A", "A"]) { store, window, host in
      let field = try XCTUnwrap(self.fields(host).first)
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.string = " \tA\u{00a0} "
      field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
      try await self.settle(host)
      window.makeFirstResponder(nil); try await self.settle(host)
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["A", "A"])
      XCTAssertEqual(self.fields(host).map(\.stringValue), ["A", "A"])
      XCTAssertTrue(self.fields(host)[0] === field)
    }
  }

  func testPointerAddKeepsInputSelectionAndOutsideReleaseDoesNotInsert() async throws {
    try await withCard(["Draft"]) { store, window, host in
      let field = try XCTUnwrap(self.fields(host).first)
      XCTAssertTrue(window.makeFirstResponder(field))
      let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
      editor.setSelectedRange(.init(location: 1, length: 3))
      let add = try self.button("voice-dictionary-add", in: host)
      try self.mouse(.leftMouseDown, on: add, window: window)
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 3))
      let outside = add.convert(.init(x: -20, y: -20), to: nil)
      let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: outside, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
      add.mouseUp(with: up); try await self.settle(host)
      XCTAssertEqual(self.fields(host).map(\.stringValue), ["Draft"])
      XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Draft"])
    }
  }

  func testProgrammaticUnmountDoesNotIntroduceAnExtraSaveWithoutBlur() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.dictationDictionary = ["Saved"]
    let window = DictionaryWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AnyView(VoiceDictionarySettingsCard(store: store).environment(\.appAppearance, store.appearance)))
    window.contentView = host; try await settle(host)
    let field = try XCTUnwrap(fields(host).first)
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.string = "Uncommitted"
    field.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor)); try await settle(host)
    host.rootView = AnyView(Text("Other page")); try await settle(host)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Saved"])
  }

  func testEnterInsertsAfterCurrentRowWithoutSavingDraftUntilRealBlur() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.dictationDictionary = ["First", "Last"]
    let window = DictionaryWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: VoiceSettingsView(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    let original = try XCTUnwrap(fields(host).first)
    XCTAssertTrue(window.makeFirstResponder(original))
    let editor = try XCTUnwrap(original.currentEditor() as? NSTextView)
    editor.string = "  中文草稿  "
    original.textDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
    try await settle(host)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.sendEvent(event); try await settle(host)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, ["First", "Last"])
    let current = fields(host)
    XCTAssertEqual(current.map(\.stringValue), ["  中文草稿  ", "", "Last"])
    XCTAssertTrue(current.first === original)
    XCTAssertTrue(current[1].currentEditor() === window.firstResponder)
    XCTAssertFalse(window.isVisible)
    window.makeFirstResponder(nil); try await settle(host)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, ["中文草稿", "Last"])
    XCTAssertEqual(fields(host).map(\.stringValue), ["中文草稿", "Last"])
  }
  private func fields(_ view: NSView) -> [NSTextField] {
    let textFields = descendants(view).compactMap { $0 as? NSTextField }
    return textFields.filter { field in
      if ["词语或短语", "Jane Doe", "Acme Widget", "checkout-form.tsx", "useCartState"].contains(field.placeholderString ?? "") { return true }
      let identifier = field.accessibilityIdentifier()
      return identifier.hasPrefix("voice-dictionary-entry-")
    }.sorted {
      let left = $0.convert($0.bounds, to: view), right = $1.convert($1.bounds, to: view)
      return view.isFlipped ? left.minY < right.minY : left.maxY > right.maxY
    }
  }
  private func withCard(_ values: [String], body: (WorkspaceStore, NSWindow, NSView) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.dictationDictionary = values
    let window = DictionaryWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: VoiceDictionarySettingsCard(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    try await body(store, window, host); XCTAssertFalse(window.isVisible)
  }
  private func button(_ identifier: String, in host: NSView) throws -> VoiceDictionaryActionButton.Control {
    try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictionaryActionButton.Control }.first { $0.accessibilityIdentifier() == identifier })
  }
  private func key(_ type: NSEvent.EventType, code: UInt16, text: String, window: NSWindow) throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    window.sendEvent(event)
  }
  private func mouse(_ type: NSEvent.EventType, on view: NSView, window: NSWindow) throws {
    let point = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    // NSView.hitTest takes the parent's coordinates, not the receiver's flipped
    // bounds. Pointer lifecycle is checked at the hit-tested control boundary;
    // the invisible window does not establish front-window pointer acceptance.
    let host = try XCTUnwrap(window.contentView)
    let parent = try XCTUnwrap(host.superview)
    XCTAssertTrue(host.hitTest(parent.convert(point, from: nil)) === view)
    if type == .leftMouseDown { view.mouseDown(with: event) }
    else { view.mouseUp(with: event) }
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded() }
}
@MainActor private final class DictionaryWindow: NSWindow { override var canBecomeKey: Bool { true } }
