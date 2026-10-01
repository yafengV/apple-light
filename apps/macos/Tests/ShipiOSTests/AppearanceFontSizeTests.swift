import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceFontSizeTests: XCTestCase {
  func testDefaultsBoundsFractionalPersistenceAndLegacyExplicitSize() throws {
    XCTAssertEqual(AppearancePreferences().uiSize, 14)
    let missing = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8))
    XCTAssertEqual(missing.uiSize, 14); XCTAssertEqual(missing.codeSize, 12)
    let explicit = try JSONDecoder().decode(AppearancePreferences.self, from: Data(#"{"uiSize":13,"codeSize":8.5}"#.utf8))
    XCTAssertEqual(explicit.uiSize, 13); XCTAssertEqual(explicit.codeSize, 8.5)
    var preferences = AppearancePreferences(); preferences.uiSize = 16.5; preferences.codeSize = 7.5
    XCTAssertEqual(preferences.normalized().uiSize, 16); XCTAssertEqual(preferences.normalized().codeSize, 8)
    preferences.uiSize = 13.75; preferences.codeSize = 23.25
    let restored = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(preferences))
    XCTAssertEqual(restored, preferences)
  }
  func testActualOfflineHTMLNumberSanitizationCommitFormattingAndInRangeGrid() async throws {
    let samples = ["", " ", "14", "14.5", "014", "+14", "-14", ".5", "14.", "14px", "14e0", "1.4e1", "14e", "0xE", "14,5", "１４", "14\n", " 14", "14 ", "NaN", "Infinity", "1e309", "1e-309", "-0", "0", "7", "7.5", "8", "8.5", "10.5", "11", "11.5", "15.5", "16", "16.5", "23.5", "24", "24.5", "25", "14.000000000000002", "11.000000000000002", "-1e309", "--14", "14e+0"]
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: .zero, configuration: configuration)
    XCTAssertNil(view.window)
    let script = """
      const cases=[];
      for(const [kind,min,max,current] of [['ui',11,16,14],['code',8,24,12]]) {
        for(const text of samples) {
          const input=document.createElement('input');input.type='number';input.min=min;input.max=max;input.step=1;input.value=text;
          const value=Number.parseFloat(input.value);
          const committed=Number.isFinite(value)&&value>=min&&value<=max?value:current;
          const steps={};
          for(const delta of [-1,1]) {input.value=text;if(delta>0)input.stepUp();else input.stepDown();steps[String(delta)]=input.value;}
          cases.push({kind,text,current,committed,output:String(committed),up:steps['1'],down:steps['-1']});
        }
      }
      return JSON.stringify(cases);
      """
    let output = try await view.callAsyncJavaScript(script, arguments: ["samples": samples], in: nil, contentWorld: .defaultClient)
    struct Case: Decodable { let kind: AppearanceFontSize; let text: String; let current: Double; let committed: Double; let output: String; let up: String; let down: String }
    let result = try JSONDecoder().decode([Case].self, from: Data(try XCTUnwrap(output as? String).utf8))
    XCTAssertEqual(result.count, 88)
    for item in result {
      let committed = item.kind.committed(item.text, current: item.current)
      XCTAssertEqual(committed, item.committed, item.kind.rawValue + "/commit/" + item.text)
      XCTAssertEqual(AppearanceFontSize.text(committed), item.output, item.kind.rawValue + "/format/" + item.text)
      // DOM methods and user arrow handlers differ outside the allowed range.
      // Compare their common in-range grid, including near-integer precision.
      if let value = item.kind.parsed(item.text), item.kind.range.contains(value) {
        XCTAssertEqual(item.kind.stepped(item.text, direction: 1), item.up, item.kind.rawValue + "/up/" + item.text)
        XCTAssertEqual(item.kind.stepped(item.text, direction: -1), item.down, item.kind.rawValue + "/down/" + item.text)
      }
    }
    let empty = try XCTUnwrap(result.first { $0.kind == .ui && $0.text.isEmpty })
    XCTAssertEqual(empty.down, "", "DOM stepDown must not be substituted for the user arrow path")
    XCTAssertEqual(AppearanceFontSize.ui.stepped("", direction: -1), "11")
    XCTAssertNil(view.window)
  }
  func testChromiumUserArrowRulesEmptyBoundsPreservedTextAndPrecision() {
    for kind in AppearanceFontSize.allCases {
      for text in ["", "invalid", "14px", "+14", "1e309"] {
        for direction in [-1, 1] { XCTAssertEqual(kind.stepped(text, direction: direction), AppearanceFontSize.text(kind.range.lowerBound)) }
      }
      for text in ["7.5", "0", "-5", "1e-309"] {
        XCTAssertEqual(kind.stepped(text, direction: -1), text)
        XCTAssertEqual(kind.stepped(text, direction: 1), AppearanceFontSize.text(kind.range.lowerBound))
      }
      for text in ["24.5", "25", "1e3"] {
        XCTAssertEqual(kind.stepped(text, direction: 1), text)
        XCTAssertEqual(kind.stepped(text, direction: -1), AppearanceFontSize.text(kind.range.upperBound))
      }
      XCTAssertEqual(kind.stepped("14.000000000000002", direction: -1), "13")
      XCTAssertEqual(kind.stepped("14.000000059604644", direction: -1), "13")
      XCTAssertEqual(kind.stepped("14.000000059604645", direction: -1), "14")
      XCTAssertEqual(kind.stepped("13.999999940395356", direction: 1), "15")
      XCTAssertEqual(kind.stepped("13.999999940395355", direction: 1), "14")
    }
    XCTAssertEqual(AppearanceFontSize.ui.stepped("0016", direction: 1), "0016")
    XCTAssertEqual(AppearanceFontSize.code.stepped("8e0", direction: -1), "8e0")
  }
  func testUIFontsFollowReferenceRoundedCSSScaleAndCodeKeepsFraction() {
    for size in [11.0, 12.5, 13, 14, 14.5, 16] {
      var appearance = AppearancePreferences(); appearance.uiSize = size; appearance.codeSize = 8.5
      for base: CGFloat in [12, 13, 14, 16, 18, 20, 24, 28, 36, 48, 72] {
        XCTAssertEqual(appearance.nativeFont(size: base).pointSize, floor(base * size / 14 + 0.5))
        XCTAssertEqual(appearance.nativeFont(size: base, content: true).pointSize, floor(base * size / 14 + 0.5))
      }
      XCTAssertEqual(appearance.nativeFont(size: 12, code: true).pointSize, 8.5)
    }
  }
  func testHiddenNumberEditorPaddingDimensionsAndAccessibilityBounds() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    XCTAssertEqual(field.frame.size, .init(width: 64, height: 28))
    XCTAssertEqual(field.accessibilityLabel(), "界面字号")
    XCTAssertEqual(field.accessibilityRole(), .incrementor)
    XCTAssertEqual(field.accessibilityMinValue() as? NSNumber, 11)
    XCTAssertEqual(field.accessibilityMaxValue() as? NSNumber, 16)
    XCTAssertFalse(field.showsArrows)
    field.hovered = true; XCTAssertTrue(field.showsArrows)
    field.hovered = false; XCTAssertFalse(field.showsArrows)
    let editor = try begin(field, window: window)
    XCTAssertTrue(field.showsArrows)
    let rect = editor.convert(editor.bounds, to: field)
    XCTAssertEqual(rect.minX, 8, accuracy: 0.5)
    XCTAssertEqual(rect.width, 42, accuracy: 0.5)
    XCTAssertGreaterThanOrEqual(rect.height, 15)
    XCTAssertLessThanOrEqual(rect.height, 28)
    XCTAssertTrue(field.accessibilityPerformIncrement()); XCTAssertEqual(editor.string, "15")
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    window.makeFirstResponder(nil); XCTAssertFalse(field.showsArrows)
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 1); XCTAssertFalse(window.isVisible)
  }
  func testLongFractionRemainsSingleLineDraftAndDetachedFieldCannotCommit() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    let text = "14.000000000000002"
    editor.string = text; field.stringValue = text
    owner.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertTrue(field.cell?.usesSingleLineMode == true); XCTAssertTrue(field.cell?.isScrollable == true)
    XCTAssertEqual(editor.string, text); XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    owner.commit(field); try await settle(host)
    XCTAssertEqual(state.value, 14.000000000000002); XCTAssertEqual(state.writes, 1)
    let current = try XCTUnwrap(find(host)), currentOwner = try XCTUnwrap(current.owner)
    current.stringValue = "15"; current.removeFromSuperview(); currentOwner.commit(current)
    XCTAssertEqual(state.value, 14.000000000000002); XCTAssertEqual(state.writes, 1); XCTAssertFalse(window.isVisible)
  }
  func testHiddenFieldEditingIsDraftUntilEnterAndInvalidInputRestoresWithoutWrite() async throws {
    let state = InputState()
    let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    editor.string = "15.5"; field.stringValue = "15.5"
    owner.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    XCTAssertTrue(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    try await settle(host)
    XCTAssertEqual(state.value, 15.5); XCTAssertEqual(state.writes, 1)
    let current = try XCTUnwrap(find(host)); XCTAssertEqual(current.stringValue, "15.5")
    let currentOwner = try XCTUnwrap(current.owner), currentEditor = try begin(current, window: window)
    for invalid in ["", "invalid", "17", "10", "14.", "Infinity"] {
      currentEditor.string = invalid; current.stringValue = invalid
      XCTAssertTrue(currentOwner.control(current, textView: currentEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
      XCTAssertEqual(current.stringValue, "15.5"); XCTAssertEqual(currentEditor.string, "15.5")
      XCTAssertEqual(state.value, 15.5); XCTAssertEqual(state.writes, 1)
    }
    XCTAssertFalse(window.isVisible)
  }
  func testBlurCommitsOnceTabPassesAndEscapeStaysInSettings() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    editor.string = "13.25"; field.stringValue = "13.25"
    XCTAssertFalse(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    XCTAssertTrue(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(editor.string, "13.25"); XCTAssertEqual(state.value, 14)
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory); store.destination = .settings
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window)); XCTAssertEqual(store.destination, .settings)
    owner.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: field))
    XCTAssertEqual(state.value, 13.25); XCTAssertEqual(state.writes, 1)
    owner.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: field))
    XCTAssertEqual(state.writes, 1); try await settle(host); XCTAssertFalse(window.isVisible)
  }
  func testArrowKeysChangeOnlyDraftAndStepAtLimitsWithoutWrapping() async throws {
    let state = InputState(); state.value = 14.5
    let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    XCTAssertTrue(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    XCTAssertEqual(editor.string, "15"); XCTAssertEqual(state.value, 14.5); XCTAssertEqual(state.writes, 0)
    owner.step(field, direction: 1); owner.step(field, direction: 1); XCTAssertEqual(editor.string, "16")
    for _ in 0..<10 { owner.step(field, direction: -1) }; XCTAssertEqual(editor.string, "11")
    owner.commit(field); XCTAssertEqual(state.value, 11); XCTAssertEqual(state.writes, 1)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }
  func testWheelStepsOnlyWhenFocusedAndKeepsDraftUntilBlur() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    XCTAssertFalse(field.handleWheel(deltaY: 1))
    XCTAssertEqual(field.stringValue, "14"); XCTAssertEqual(state.writes, 0)
    let editor = try begin(field, window: window)
    XCTAssertTrue(field.handleWheel(deltaY: 1)); XCTAssertEqual(editor.string, "15")
    XCTAssertTrue(field.handleWheel(deltaY: -1)); XCTAssertEqual(editor.string, "14")
    XCTAssertTrue(field.handleWheel(deltaY: 0)); XCTAssertEqual(editor.string, "14")
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    XCTAssertTrue(field.handleWheel(deltaY: 1))
    window.makeFirstResponder(nil)
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 1)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }
  func testHeldArrowRepeatsUntilReleaseWithoutSaving() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let editor = try begin(field, window: window)
    field.beginArrowHold(direction: 1)
    XCTAssertEqual(editor.string, "15"); XCTAssertEqual(state.writes, 0)
    try await Task.sleep(for: .milliseconds(620))
    XCTAssertEqual(editor.string, "16"); XCTAssertEqual(state.value, 14)
    field.cancelArrowHold()
    XCTAssertNil(field.arrowDirection)
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(editor.string, "16"); XCTAssertEqual(state.writes, 0)
    window.makeFirstResponder(nil)
    XCTAssertEqual(state.value, 16); XCTAssertEqual(state.writes, 1)
    try await settle(host)
  }
  func testHeldArrowStopsWhenFieldLosesFocus() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    _ = try begin(field, window: window)
    field.beginArrowHold(direction: 1)
    window.makeFirstResponder(nil)
    XCTAssertNil(field.arrowDirection)
    XCTAssertEqual(state.value, 15)
    try await Task.sleep(for: .milliseconds(620))
    XCTAssertEqual(state.value, 15); XCTAssertEqual(state.writes, 1)
    try await settle(host)
  }
  func testInputMethodMarkedTextCannotCommitStepOrConsumeReturn() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    editor.setMarkedText("15", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: editor.string.utf16.count))
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertFalse(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    owner.commit(field); owner.step(field, direction: 1)
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 0)
    XCTAssertTrue(editor.hasMarkedText()); editor.unmarkText(); try await settle(host); XCTAssertFalse(window.isVisible)
  }
  func testRejectedWriteRestoresEditorAndKeepsOtherDraftAndFocus() async throws {
    let state = InputState(); state.reject = true
    let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    editor.string = "15"; field.stringValue = "15"; owner.commit(field)
    try await settle(host)
    XCTAssertEqual(state.value, 14); XCTAssertEqual(state.writes, 1)
    XCTAssertEqual(field.stringValue, "14"); XCTAssertEqual(editor.string, "14")
    XCTAssertTrue(window.firstResponder === editor); XCTAssertTrue(field.window === window); XCTAssertFalse(window.isVisible)
  }
  func testDisabledHiddenAndDismantledControlsCannotWrite() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner)
    field.stringValue = "15"; field.isHidden = true; owner.commit(field)
    XCTAssertEqual(state.writes, 0); XCTAssertFalse(field.accessibilityPerformIncrement())
    field.isHidden = false; state.enabled = false; try await settle(host)
    field.stringValue = "15"; owner.commit(field); XCTAssertEqual(state.writes, 0)
    state.enabled = true; state.mounted = false; try await settle(host)
    owner.commit(field); XCTAssertEqual(state.writes, 0); XCTAssertNil(field.window); XCTAssertFalse(window.isVisible)
  }
  func testCommittedValueRekeysOnlyNumberFieldAndExternalValueDropsOldDraft() async throws {
    let state = InputState(); let (window, host, field) = try await host(state); defer { window.close() }
    let owner = try XCTUnwrap(field.owner), editor = try begin(field, window: window)
    editor.string = "15"; field.stringValue = "15"
    state.value = 12; try await settle(host)
    let replacement = try XCTUnwrap(find(host)); XCTAssertFalse(replacement === field)
    XCTAssertEqual(replacement.stringValue, "12"); XCTAssertNil(field.window)
    owner.commit(field); XCTAssertEqual(state.value, 12); XCTAssertEqual(state.writes, 0); XCTAssertFalse(window.isVisible)
  }
  func testAppearanceFormPersistenceFailureRetainsFieldsAndOtherSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-size-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["keep"] = "draft"; store.library.preferredEditor = "xcode"
    let (window, host) = try await makeHost(AnyView(AppearanceSettingsView(store: store).environment(\.appAppearance, store.appearance)))
    defer { window.close() }
    let code = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "代码字号" })
    let owner = try XCTUnwrap(code.owner), editor = try begin(code, window: window)
    editor.string = "8.5"; code.stringValue = "8.5"; owner.commit(code); try await settle(host)
    XCTAssertEqual(store.appearance.codeSize, 8.5)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance?.codeSize, 8.5)
    let current = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "代码字号" })
    let currentOwner = try XCTUnwrap(current.owner), currentEditor = try begin(current, window: window)
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    currentEditor.string = "10"; current.stringValue = "10"; currentOwner.commit(current); try await settle(host)
    XCTAssertEqual(store.appearance.codeSize, 8.5); XCTAssertEqual(current.stringValue, "8.5")
    XCTAssertTrue(fields(host).first { $0.accessibilityLabel() == "代码字号" } === current)
    XCTAssertTrue(current.window === window); XCTAssertTrue(window.firstResponder === currentEditor)
    XCTAssertNotNil(store.generalSettingsError); XCTAssertEqual(store.library.drafts["keep"], "draft")
    XCTAssertEqual(store.library.preferredEditor, "xcode"); XCTAssertFalse(window.isVisible)
  }
  private func find(_ view: NSView) -> AppearanceFontSizeInput.Control? { fields(view).first }
  private func fields(_ view: NSView) -> [AppearanceFontSizeInput.Control] {
    (view as? AppearanceFontSizeInput.Control).map { [$0] } ?? view.subviews.flatMap(fields)
  }
  private func begin(_ field: AppearanceFontSizeInput.Control, window: NSWindow) throws -> NSTextView {
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    field.owner?.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: field))
    return editor
  }
  private func host(_ state: InputState) async throws -> (NSWindow, NSHostingView<AnyView>, AppearanceFontSizeInput.Control) {
    let (window, host) = try await makeHost(AnyView(InputFixture(state: state).frame(width: 500, height: 400)))
    return (window, host, try XCTUnwrap(find(host)))
  }
  private func makeHost(_ root: AnyView) async throws -> (NSWindow, NSHostingView<AnyView>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: root); window.contentView = host; try await settle(host)
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
  }
}
@MainActor @Observable private final class InputState {
  var value = 14.0
  var writes = 0
  var reject = false
  var enabled = true
  var mounted = true
}
private struct InputFixture: View {
  let state: InputState
  var body: some View {
    if state.mounted {
      AppearanceFontSizeInput(kind: .ui, value: Binding(get: { state.value }, set: { value in
        state.writes += 1; if !state.reject { state.value = value }
      })).frame(width: 64, height: 28).id(state.value).disabled(!state.enabled)
    }
  }
}
