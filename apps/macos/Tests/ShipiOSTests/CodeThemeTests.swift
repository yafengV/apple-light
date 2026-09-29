import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CodeThemeTests: XCTestCase {
  private struct Reference: Decodable {
    struct Item: Decodable { let id: String; let label: String; let variant: String; let seed: CodeThemePreset.Seed }
    let cases: [Item]
  }
  private struct Tokens: Decodable {
    struct Item: Decodable {
      struct Sample: Decodable {
        struct Token: Decodable, Equatable { var content: String; let style: CodeSyntaxToken.Style }
        let path: String; let lines: [String]; let expected: [[Token]]
      }
      let id: String; let variant: String; let samples: [Sample]
    }
    let cases: [Item]
  }
  private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
  }
  private func tempStore() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-theme-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  func testCatalogAndPaletteFactsMatchAllCurrentCodexVariants() throws {
    let reference = try JSONDecoder().decode(Reference.self, from: fixture("code_theme_catalog_reference"))
    XCTAssertEqual(CodeThemeCatalog.presets.count, 28)
    XCTAssertEqual(CodeThemeCatalog.options(dark: false).count, 16); XCTAssertEqual(CodeThemeCatalog.options(dark: true).count, 27)
    XCTAssertEqual(CodeThemeCatalog.presets.map(\.label), CodeThemeCatalog.presets.map(\.label).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    XCTAssertEqual(reference.cases.count, 43)
    for item in reference.cases {
      let preset = try XCTUnwrap(CodeThemeCatalog.preset(item.id, dark: item.variant == "dark")), variant = try XCTUnwrap(preset.variant(dark: item.variant == "dark"))
      XCTAssertEqual(preset.label, item.label)
      XCTAssertEqual(variant.seed.accent, item.seed.accent); XCTAssertEqual(variant.seed.surface, item.seed.surface)
      XCTAssertEqual(variant.seed.ink, item.seed.ink); XCTAssertEqual(variant.seed.contrast, item.seed.contrast)
      XCTAssertEqual(variant.seed.opaqueWindows, item.seed.opaqueWindows); XCTAssertEqual(variant.seed.fonts, item.seed.fonts)
      XCTAssertEqual(variant.seed.semanticColors?.diffAdded, item.seed.semanticColors?.diffAdded)
      XCTAssertEqual(variant.seed.semanticColors?.diffRemoved, item.seed.semanticColors?.diffRemoved)
    }
  }
  func testActualWebKitMatchesEveryThemeStyleAndPreservesAllSourceBytes() async throws {
    let reference = try JSONDecoder().decode(Tokens.self, from: fixture("code_theme_tokens_reference")), service = CodeSyntaxService()
    func merge(_ rows: [[Tokens.Item.Sample.Token]]) -> [[Tokens.Item.Sample.Token]] {
      rows.map { row in row.reduce(into: []) { result, token in
        if result.last?.style == token.style { result[result.count - 1].content += token.content } else { result.append(token) }
      } }
    }
    for item in reference.cases { for sample in item.samples {
      let pair = item.variant == "dark" ? CodeThemePair(dark: item.id) : CodeThemePair(light: item.id)
      let input = CodeSyntaxInput(path: sample.path, source: sample.lines.joined(separator: "\n"), themes: pair)
      let result = try await service.highlight(input); try result.validate(input)
      let actual = result.right.map { row in row.tokens.map { Tokens.Item.Sample.Token(content: $0.content, style: item.variant == "dark" ? $0.dark : $0.light) } }
      XCTAssertEqual(merge(actual), merge(sample.expected), item.id + "/" + item.variant + "/" + sample.path)
    } }
    XCTAssertTrue(service.usesIsolatedDocument); XCTAssertNil(service.view?.window)
  }
  func testPresetChangesOnlyItsVariantAndKeepsUnspecifiedFontsContrastAndDrafts() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.contrast = 77; appearance.light.uiFont = "Menlo"; appearance.light.codeFont = "Monaco"
    let oldDark = appearance.dark
    let github = try XCTUnwrap(appearance.selectingCodeTheme("github", dark: false))
    XCTAssertEqual(github.codeThemes.light, "github"); XCTAssertEqual(github.codeThemes.dark, "codex")
    XCTAssertEqual(github.dark, oldDark); XCTAssertEqual(github.light.contrast, 77)
    XCTAssertEqual(github.light.uiFont, "Menlo"); XCTAssertEqual(github.light.codeFont, "Monaco")
    let linear = try XCTUnwrap(github.selectingCodeTheme("linear", dark: false))
    XCTAssertEqual(linear.light.uiFont, "Inter"); XCTAssertFalse(linear.light.translucentSidebar)
    let xcode = try XCTUnwrap(linear.selectingCodeTheme("xcode", dark: false))
    XCTAssertEqual(xcode.light.codeFont, "\"SFMono-Regular\""); XCTAssertEqual(xcode.light.uiFont, "Inter")
    XCTAssertNotNil(xcode.nativeFont(size: 12, code: true))
    let notion = try XCTUnwrap(xcode.selectingCodeTheme("notion", dark: false))
    XCTAssertEqual(notion.light.uiFont, ""); XCTAssertEqual(notion.light.codeFont, "")
    XCTAssertEqual(notion.light.contrast, 77)
    XCTAssertNil(appearance.selectingCodeTheme("dracula", dark: false)); XCTAssertNil(appearance.selectingCodeTheme("proof", dark: true))
  }
  func testIndependentThemePersistenceMigrationResetAndExportRoundTrip() throws {
    let (store, root) = tempStore(); store.library.drafts["fixture"] = "keep"; store.library.preferredEditor = "xcode"
    var callbacks = 0; store.appearanceHandler = { _ in callbacks += 1 }
    XCTAssertTrue(store.selectCodeTheme("github", dark: false)); XCTAssertTrue(store.selectCodeTheme("dracula", dark: true))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.appearance?.codeThemes, .init(light: "github", dark: "dracula")); XCTAssertEqual(restored.drafts["fixture"], "keep")
    XCTAssertEqual(restored.preferredEditor, "xcode"); XCTAssertEqual(callbacks, 2)
    XCTAssertEqual(try AppearanceThemeFile.decode(JSONEncoder().encode(AppearanceThemeFile(appearance: store.appearance))), store.appearance)
    var invalid = AppearancePreferences(); invalid.codeThemes = .init(light: "dracula", dark: "proof")
    XCTAssertEqual(invalid.normalized().codeThemes, .init())
    XCTAssertEqual(try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8)).codeThemes, .init())
    XCTAssertTrue(store.commitAppearance(.init())); XCTAssertEqual(store.appearance.codeThemes, .init())
    XCTAssertEqual(store.library.drafts["fixture"], "keep"); XCTAssertEqual(callbacks, 3)
  }
  func testThemeFailureDoesNotPublishApplyCallbackOrDiscardDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-failure-" + UUID().uuidString)
    try Data("file".utf8).write(to: root); defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.library.drafts["fixture"] = "keep"
    var callbacks = 0; store.appearanceHandler = { _ in callbacks += 1 }
    XCTAssertFalse(store.selectCodeTheme("github", dark: false)); XCTAssertEqual(store.appearance, .init())
    XCTAssertEqual(callbacks, 0); XCTAssertEqual(store.library.drafts["fixture"], "keep"); XCTAssertNotNil(store.generalSettingsError)
  }
  func testPresetCSSFontFallbacksChooseFirstInstalledFamilyAndSupportMonospaceUI() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.codeFont = "\"ShipiOS-Missing-Font\", Menlo, monospace"
    XCTAssertEqual(appearance.nativeFont(size: 12, code: true).familyName, "Menlo")
    appearance.light.uiFont = "ui-monospace, \"ShipiOS-Missing-Font\""
    XCTAssertEqual(appearance.nativeFont(size: 13).fontName, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
    appearance.light.uiFont = "\"ShipiOS-Missing-Font\", system-ui"
    XCTAssertEqual(appearance.nativeFont(size: 13).fontName, NSFont.systemFont(ofSize: 13).fontName)
  }
  func testThemesHaveDistinctCachesButRetainSourceIdentityAndWordRanges() async throws {
    let diff = ReviewDiff("@@ -1,1 +1,1 @@\n-let a = 1\n+let a = 2\n"), service = CodeSyntaxService()
    let a = CodeSyntaxInput(path: "Main.swift", diff: diff, wordDiffs: true)
    let b = CodeSyntaxInput(path: "Main.swift", diff: diff, wordDiffs: true, themes: .init(light: "github", dark: "dracula"))
    XCTAssertNotEqual(a.identity, b.identity); XCTAssertTrue(a.identity.matchesSource(b.identity))
    let first = try await service.highlight(a), second = try await service.highlight(b)
    XCTAssertNotEqual(first.right[0].tokens.first?.light.color, second.right[0].tokens.first?.light.color)
    XCTAssertEqual(first.right[0].changes, second.right[0].changes)
    let again = try await service.highlight(a); XCTAssertEqual(again, first)
  }
  func testNativeThemeSwitchPreservesSelectionScrollFocusAndSource() async throws {
    _ = NSApplication.shared
    let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 500, height: 160))
    let text = NSTextView(frame: .init(x: 0, y: 0, width: 500, height: 5000))
    text.isVerticallyResizable = true; text.isEditable = false
    let source = Array(repeating: "let name = \"你好 👩🏽‍💻\"", count: 180).joined(separator: "\n")
    text.string = source; scroll.documentView = text
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = scroll
    defer { window.close() }
    let controller = FilePreviewSyntaxController(service: CodeSyntaxService())
    var appearance = AppearancePreferences(); appearance.theme = "light"
    controller.update(text, path: "Main.swift", source: source, ready: true, appearance: appearance)
    func color() -> String? {
      guard let color = text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
        let rgb = color.usingColorSpace(.sRGB) else { return nil }
      return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    for _ in 0..<200 { if color() == "#D53538" { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(color(), "#D53538")
    text.setSelectedRange(.init(location: 8, length: 4)); text.layoutManager?.ensureLayout(for: text.textContainer!)
    scroll.contentView.scroll(to: .init(x: 0, y: 350)); scroll.reflectScrolledClipView(scroll.contentView)
    window.makeFirstResponder(text); let ranges = text.selectedRanges, origin = scroll.contentView.bounds.origin
    appearance = try XCTUnwrap(appearance.selectingCodeTheme("github", dark: false))
    controller.update(text, path: "Main.swift", source: source, ready: true, appearance: appearance)
    for _ in 0..<200 { if color() == "#CF222E" { break }; try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(color(), "#CF222E"); XCTAssertEqual(text.selectedRanges, ranges)
    XCTAssertEqual(scroll.contentView.bounds.origin, origin); XCTAssertTrue(window.firstResponder === text)
    XCTAssertTrue(text.string.utf8.elementsEqual(source.utf8)); XCTAssertFalse(window.isVisible)
    controller.stop()
  }
  func testSettingsSearchHasSeparateLightAndDarkCodeThemeTargets() {
    let targets = SettingsSearch.results(for: "代码主题").compactMap(\.field)
    XCTAssertTrue(targets.contains(.lightCodeTheme)); XCTAssertTrue(targets.contains(.darkCodeTheme))
    XCTAssertEqual(SettingsSearchField.lightCodeTheme.page, .appearance)
  }
  func testHiddenAppearancePageMenusApplyPresetWithoutChangingTaskOrOpeningAnotherWindow() async throws {
    _ = NSApplication.shared
    let (store, root) = tempStore(); store.library.drafts["fixture"] = "keep"
    var appearance = AppearancePreferences(); appearance.theme = "light"; store.appearance = appearance
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 1600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = host
    func controls(_ view: NSView) -> [CodeThemeMenuButton.Control] {
      (view as? CodeThemeMenuButton.Control).map { [$0] } ?? view.subviews.flatMap(controls)
    }
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let light = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "浅色代码主题" })
    let dark = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "深色代码主题" })
    let lightOwner = try XCTUnwrap(light.owner), darkOwner = try XCTUnwrap(dark.owner)
    lightOwner.toggle(light, keyboard: false)
    XCTAssertEqual(lightOwner.parent.menu.options.count, 16)
    XCTAssertNotNil(lightOwner.popup); XCTAssertTrue(lightOwner.popup?.window === window)
    lightOwner.choose("github", button: light)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.codeThemes, .init(light: "github"))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance?.codeThemes, .init(light: "github"))
    XCTAssertEqual(store.library.drafts["fixture"], "keep"); XCTAssertTrue(window.firstResponder === light)
    XCTAssertEqual(light.title, "GitHub"); XCTAssertFalse(window.isVisible)
    darkOwner.toggle(dark, keyboard: false); XCTAssertEqual(darkOwner.parent.menu.options.count, 27)
    darkOwner.dismiss(dark, restore: true)
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    lightOwner.toggle(light, keyboard: false); lightOwner.choose("xcode", button: light)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.codeThemes, .init(light: "github"))
    XCTAssertEqual(light.title, "GitHub"); XCTAssertNotNil(store.generalSettingsError)
    XCTAssertNil(lightOwner.popup); XCTAssertFalse(lightOwner.parent.menu.presented)
    XCTAssertTrue(light.window === window, "The original picker must remain attached after showing an error")
    XCTAssertTrue(controls(host).first { $0.accessibilityLabel() == "浅色代码主题" } === light, "Showing the error must retain the picker identity")
    XCTAssertTrue(window.firstResponder === light)
    XCTAssertEqual(store.library.drafts["fixture"], "keep"); XCTAssertFalse(window.isVisible)
  }
}
