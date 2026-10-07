import AppKit
import CoreText
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class FontSmoothingTests: XCTestCase {
  func testPublicDefaultControlAndRuntimeEffectsKeepAntialiasingSemantics() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "font_smoothing_reference_652", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(reference["version"] as? String, "26.930.51102")
    XCTAssertEqual(reference["defaultEnabled"] as? Bool, AppearancePreferences().useFontSmoothing)
    XCTAssertEqual(reference["baseAntialiased"] as? Bool, true)
    let controls = try XCTUnwrap(reference["controls"] as? [[String: Any]])
    XCTAssertEqual(controls.count, 6)
    for sample in controls {
      let visible = sample["platform"] as? String == "macOS"
      XCTAssertEqual(sample["visible"] as? Bool, visible)
      let writes = try XCTUnwrap(sample["writes"] as? [[String: Any]])
      XCTAssertEqual(writes.count, visible ? 2 : 0)
      if visible {
        XCTAssertEqual(sample["label"] as? String, "Font smoothing")
        XCTAssertEqual(sample["description"] as? String, "Use native macOS font anti-aliasing")
        let checked = try XCTUnwrap(sample["checked"] as? Bool)
        XCTAssertEqual(writes.compactMap { $0["value"] as? Bool }, [!checked, checked])
      }
    }
    let effects = try XCTUnwrap(reference["effects"] as? [[String: Any]])
    XCTAssertEqual(effects.count, 8)
    for sample in effects {
      let expected: String? = sample["ready"] as? Bool == false ? "old-override"
        : sample["os"] as? String == "darwin" && sample["enabled"] as? Bool == true ? "antialiased" : nil
      XCTAssertEqual(sample["root"] as? String, expected)
      XCTAssertEqual(sample["body"] as? String, expected)
    }
  }

  func testMigrationExportAndAdvancedResetKeepIndependentRenderingPreference() throws {
    let decoder = JSONDecoder()
    XCTAssertTrue(try decoder.decode(AppearancePreferences.self, from: Data("{}".utf8)).useFontSmoothing)
    var value = AppearancePreferences(); value.useFontSmoothing = false; value.theme = "dark"
    value.dark.uiFont = "Menlo"; value.dark.accent = "#123456"
    XCTAssertEqual(try AppearanceThemeFile.decode(JSONEncoder().encode(AppearanceThemeFile(appearance: value))), value)
    XCTAssertTrue(value.hasAdvancedChanges)
    let reset = value.resettingAdvanced()
    XCTAssertTrue(reset.useFontSmoothing); XCTAssertFalse(reset.hasAdvancedChanges)
    XCTAssertEqual(reset.theme, value.theme); XCTAssertEqual(reset.dark.uiFont, value.dark.uiFont)
    XCTAssertEqual(reset.dark.accent, value.dark.accent)
  }

  func testSaveFailureDoesNotPublishRenderingPreferenceAndRetryRestoresFromDisk() throws {
    let store = try fixtureStore(), file = store.dataRoot.appendingPathComponent("workspace.json")
    var callbacks: [Bool] = []; store.appearanceHandler = { callbacks.append($0.useFontSmoothing) }
    var value = store.appearance; value.useFontSmoothing = false
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertFalse(store.commitAppearance(value)); XCTAssertTrue(store.appearance.useFontSmoothing)
    XCTAssertTrue(callbacks.isEmpty); XCTAssertNotNil(store.generalSettingsError)
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(store.commitAppearance(value)); XCTAssertEqual(callbacks, [false]); XCTAssertNil(store.generalSettingsError)
    XCTAssertTrue(store.commitAppearance(value)); XCTAssertEqual(callbacks, [false])
    let restored = try WorkspaceLibrary.load(from: file)
    XCTAssertEqual(restored.appearance?.useFontSmoothing, false)
    XCTAssertEqual(restored.drafts["fixture"], "中文 draft 🧭")
  }

  func testSearchResolvesIndependentPreferenceForEveryTheme() {
    for theme in ["light", "dark", "system"] {
      for query in ["字体平滑", "font smoothing", "字体抗锯齿"] {
        let matches = SettingsSearch.results(for: query, appearanceTheme: theme).filter { $0.field == .fontSmoothing }
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches.first?.page, .appearance)
      }
    }
    XCTAssertNil(SettingsSearchField.fontSmoothing.appearanceVariant)
  }

  func testEnvironmentUpdateKeepsLiveTextViewIdentitySelectionUndoAndComposition() async throws {
    _ = NSApplication.shared
    var draft = "中文 draft 🧭", focused = false
    let request = UUID()
    let binding = Binding(get: { draft }, set: { draft = $0 })
    let factories: [(AppearancePreferences) -> AnyView] = [
      { AnyView(SettingsTextEditor(text: binding, label: "settings").environment(\.appAppearance, $0)) },
      { AnyView(ComposerTextEditor(text: binding, focused: Binding(get: { focused }, set: { focused = $0 }),
          plainTextMode: false, placeholder: "Message", accessibilityLabel: "composer", focusRequest: request,
          onKey: { _, _, _ in false }, onPasteAttachments: { _ in }).environment(\.appAppearance, $0)) },
      { AnyView(PullRequestTextEditor(text: binding, field: .body, focus: nil, submit: {}, cancel: {})
          .environment(\.appAppearance, $0)) },
      { AnyView(LegacyMessageLinkText(text: AttributedString(draft), fontSize: 14, weight: .regular,
          actions: MessageLinkActions(activate: { _, _ in }, perform: { _, _ in })).environment(\.appAppearance, $0)) },
      { AnyView(PRCommentMarkdownText(text: AttributedString(draft), font: .systemFont(ofSize: 14), lineHeight: 28, source: draft, layout: nil)
          .environment(\.appAppearance, $0)) }
    ]
    for factory in factories {
      let window = window(), host = NSHostingView(rootView: factory(AppearancePreferences()))
      window.contentView = host; try await settle(host)
      let editor = try XCTUnwrap(find(host, AppearanceTextView.self).first)
      let original = editor.string; editor.setSelectedRange(.init(location: 3, length: 4))
      let selection = editor.selectedRange()
      let sentinel = NSObject(); editor.undoManager?.registerUndo(withTarget: sentinel) { _ in }
      let hadUndo = editor.undoManager?.canUndo
      var value = AppearancePreferences(); value.useFontSmoothing = false
      host.rootView = factory(value); try await settle(host)
      XCTAssertTrue(find(host, AppearanceTextView.self).first === editor)
      XCTAssertFalse(editor.useFontSmoothing); XCTAssertEqual(editor.string, original)
      XCTAssertEqual(editor.selectedRange(), selection); XCTAssertEqual(editor.undoManager?.canUndo, hadUndo)
      if editor.isEditable {
        editor.setMarkedText("pin", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        host.rootView = factory(AppearancePreferences()); try await settle(host)
        XCTAssertTrue(editor.useFontSmoothing); XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
      }
      window.close()
    }
  }

  func testFileEditorReceivesPreferenceWithoutReplacingSourceSelection() async throws {
    let store = try fixtureStore(), workspace = store.workspace
    let window = window()
    defer { window.close() }
    func root(_ value: Bool) -> some View {
      var appearance = AppearancePreferences(); appearance.useFontSmoothing = value
      return FileSourcePreview(store: store, workspace: workspace).environment(\.appAppearance, appearance)
    }
    let host = NSHostingView(rootView: root(true)); window.contentView = host; try await settle(host)
    let editor = try XCTUnwrap(find(host, FilePreviewTextView.self).first)
    host.rootView = root(false); try await settle(host)
    XCTAssertTrue(find(host, FilePreviewTextView.self).first === editor); XCTAssertFalse(editor.useFontSmoothing)
    host.rootView = root(true); try await settle(host); XCTAssertTrue(editor.useFontSmoothing)
  }

  func testNativeDrawingEnablesGrayscaleAntialiasingAndRestoresInheritedContext() throws {
    let off = try raster(enabled: false), on = try raster(enabled: true)
    XCTAssertNotEqual(on, off, "The policy must reach actual Core Text drawing, not just a stored flag")
    // Both images draw the second line after the scoped override. Its bytes must
    // be identical: enabling smoothing must not leak into later native drawing.
    for y in 0..<96 {
      let start = (y * 512 + 220) * 4, end = (y * 512 + 512) * 4
      XCTAssertEqual(on[start..<end], off[start..<end])
    }
  }

  func testOwnedWebDocumentClearsOverridesAndRetainsSelectionWhenDisabled() async throws {
    let syntax = CodeSyntaxState(), window = window(); defer { window.close() }
    func root(_ enabled: Bool) -> AppearanceCodeSurface {
      var value = AppearancePreferences(); value.useFontSmoothing = enabled
      return AppearanceCodeSurface(appearance: value, syntax: syntax)
    }
    let host = NSHostingView(rootView: root(true)); window.contentView = host; try await settle(host)
    let web = try XCTUnwrap(find(host, AppearanceCodeSurface.WebView.self).first)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if (try? await web.callAsyncJavaScript("return document.body.dataset.ready==='true'", in: nil, contentWorld: .page)) as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let script = "return [document.documentElement,document.body].map(n=>({inline:n.style.getPropertyValue('-webkit-font-smoothing'),computed:getComputedStyle(n).webkitFontSmoothing}))"
    let initialResult = try await web.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    let initial = try XCTUnwrap(initialResult as? [[String: String]])
    XCTAssertEqual(initial.map { $0["inline"] }, ["antialiased", "antialiased"])
    _ = try await web.callAsyncJavaScript("const range=document.createRange();range.selectNodeContents(document.querySelector('.code'));getSelection().removeAllRanges();getSelection().addRange(range);return true", in: nil, contentWorld: .page)
    let selected = try await web.callAsyncJavaScript("return getSelection().toString()", in: nil, contentWorld: .page) as? String
    XCTAssertFalse(selected?.isEmpty ?? true)
    host.rootView = root(false); try await settle(host)
    let disabledResult = try await web.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    let disabled = try XCTUnwrap(disabledResult as? [[String: String]])
    XCTAssertEqual(disabled.map { $0["inline"] }, ["", ""])
    XCTAssertEqual(disabled.map { $0["computed"] }, ["antialiased", "antialiased"], "Base stylesheet still antialiases text after removing the inline override")
    let after = try await web.callAsyncJavaScript("return getSelection().toString()", in: nil, contentWorld: .page) as? String
    XCTAssertEqual(after, selected)
    XCTAssertTrue(find(host, AppearanceCodeSurface.WebView.self).first === web)
    XCTAssertFalse(window.isVisible)
  }

  private func raster(enabled: Bool) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 96, bitsPerComponent: 8, bytesPerRow: 512 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 512, height: 96))
    context.setShouldAntialias(false); context.setShouldSmoothFonts(false)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Native Aa 字体", attributes: [
      .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]))
    context.textPosition = .init(x: 10, y: 32)
    AppearanceFontSmoothing.draw(enabled: enabled, in: context) { CTLineDraw(line, context) }
    context.textPosition = .init(x: 230, y: 32); CTLineDraw(line, context)
    return Data(bytes: try XCTUnwrap(context.data), count: 512 * 96 * 4)
  }
  private func fixtureStore() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-smoothing-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["fixture"] = "中文 draft 🧭"
    try store.library.save(to: root.appendingPathComponent("workspace.json"))
    return store
  }
  private func window() -> NSWindow {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; return window
  }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func settle(_ view: NSView) async throws { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120)); view.layoutSubtreeIfNeeded() }
}
