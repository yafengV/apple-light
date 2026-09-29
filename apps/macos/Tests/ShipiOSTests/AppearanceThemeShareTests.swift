import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceThemeShareTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Item: Decodable { let value: AppearanceThemeShare; let text: String; let uriText: String }
    let cases: [Item]
  }
  private func fixture() throws -> Fixture {
    try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: XCTUnwrap(
      Bundle.module.url(forResource: "theme_share_reference", withExtension: "json", subdirectory: "Fixtures"))))
  }
  private func store() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-share-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  func testCurrentReferenceEncoderTextAndURIFormsRoundTripAllVariantsDefaultsAndUnicodeFaces() throws {
    let items = try fixture().cases; XCTAssertEqual(items.count, 46)
    for item in items {
      let dark = item.value.variant == "dark"
      XCTAssertEqual(try AppearanceThemeShare.decode(" \n" + item.text + "\n ", dark: dark), item.value)
      XCTAssertEqual(try AppearanceThemeShare.decode(item.uriText, dark: dark), item.value)
      let value = try AppearancePreferences().importingThemeShare(item.text, dark: dark)
      XCTAssertEqual(value.themeShare(dark: dark), item.value, item.value.codeThemeId + item.value.variant)
      XCTAssertEqual(try AppearanceThemeShare.decode(value.themeShare(dark: dark).encoded(), dark: dark), item.value)
    }
  }
  func testInvalidClassificationSchemaTypesRequiredFontsAndEncodingCannotModifyAppearance() throws {
    let base = try XCTUnwrap(fixture().cases.first { $0.value.variant == "light" })
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.text.dropFirst(AppearanceThemeShare.prefix.count).utf8)) as? [String: Any])
    func text(_ change: (inout [String: Any]) -> Void) throws -> String {
      var value = object; change(&value)
      return AppearanceThemeShare.prefix + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    let bad = try [
      text { $0["variant"] = "dark" }, text { $0["codeThemeId"] = "dracula" }, text { $0["codeThemeId"] = "unknown" },
      text { var t = $0["theme"] as! [String: Any]; t["contrast"] = 101; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["contrast"] = 12.5; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["contrast"] = true; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["accent"] = "#12345678"; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["accentSource"] = NSNull(); $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["opaqueWindows"] = "false"; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["fonts"] = ["ui": NSNull()]; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t["fonts"] = ["ui": NSNull(), "code": NSNull(), "uiFace": NSNull()]; $0["theme"] = t },
      text { var t = $0["theme"] as! [String: Any]; t.removeValue(forKey: "semanticColors"); $0["theme"] = t }
    ] + ["codex-theme-v2:{}", "codex-theme-v1:%ZZ", "codex-theme-v1:[]", "codex-theme-v1:null", String(repeating: "x", count: 65_537)]
    let (store, _) = store(); store.library.drafts["fixture"] = "keep"
    var callbacks = 0; store.appearanceHandler = { _ in callbacks += 1 }
    for value in bad { XCTAssertFalse(store.importThemeShare(value, dark: false)); XCTAssertEqual(store.appearance, .init()); XCTAssertEqual(callbacks, 0) }
    XCTAssertEqual(store.library.drafts["fixture"], "keep")
  }
  func testImportReplacesOnlyOneVariantResetsMissingFontsAndPersistsIndependentTaskState() throws {
    let (store, root) = store(); var before = AppearancePreferences(); before.theme = "dark"
    before.uiFont = "Helvetica"; before.codeFont = "Menlo"; before.light.contentFont = "Georgia"
    before.dark = try XCTUnwrap(before.selectingCodeTheme("dracula", dark: true)).dark
    store.appearance = before; store.library.drafts["fixture"] = "keep"
    let sample = try XCTUnwrap(fixture().cases.first { $0.value.codeThemeId == "codex" && $0.value.variant == "light" })
    XCTAssertTrue(store.importThemeShare(sample.text, dark: false))
    XCTAssertEqual(store.appearance.theme, "dark"); XCTAssertEqual(store.appearance.dark, before.dark)
    XCTAssertEqual(store.appearance.light.uiFont, ""); XCTAssertEqual(store.appearance.light.contentFont, "")
    XCTAssertEqual(store.appearance.light.codeFont, ""); XCTAssertEqual(store.appearance.fontFamily(.ui, dark: false), "")
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.appearance, store.appearance); XCTAssertEqual(restored.drafts["fixture"], "keep")
    XCTAssertEqual(store.appearance.uiFont, "Helvetica"); XCTAssertEqual(store.appearance.codeFont, "Menlo")
  }
  func testImportNormalizesColorCaseAndBlankContentFontToFollowUIWithoutKeepingOldFace() throws {
    var share = try XCTUnwrap(fixture().cases.first { $0.value.variant == "light" }).value
    share = .init(codeThemeId: share.codeThemeId, theme: .init(accent: share.theme.accent.uppercased(),
      accentSource: share.theme.accentSource, contrast: share.theme.contrast,
      fonts: .init(code: nil, ui: "  Georgia  ", content: " \n ", codeFace: nil, uiFace: nil,
        contentFace: .init(family: "Helvetica", fullName: "Helvetica Bold", postscriptName: "Helvetica-Bold")),
      ink: share.theme.ink.uppercased(), opaqueWindows: share.theme.opaqueWindows,
      semanticColors: share.theme.semanticColors, surface: share.theme.surface.uppercased()), variant: "light")
    var original = AppearancePreferences(); original.theme = "light"
    let appearance = try original.importingThemeShare(share.encoded(), dark: false)
    XCTAssertEqual(appearance.light.uiFont, "Georgia"); XCTAssertEqual(appearance.light.contentFont, "")
    XCTAssertNil(appearance.light.contentFace); XCTAssertEqual(appearance.nativeFont(size: 14, content: true).familyName, "Georgia")
    XCTAssertEqual(appearance.themeShare(dark: false).theme.accent, share.theme.accent.lowercased())
    XCTAssertNil(appearance.themeShare(dark: false).theme.fonts.content)
  }
  func testFailedImportAndFontChangeRetainOriginalValuesAndNeverCallApply() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-share-failure-" + UUID().uuidString)
    try Data("file".utf8).write(to: root); defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.library.drafts["fixture"] = "keep"
    var callbacks = 0; store.appearanceHandler = { _ in callbacks += 1 }
    let sample = try XCTUnwrap(fixture().cases.first { $0.value.variant == "light" })
    XCTAssertFalse(store.importThemeShare(sample.text, dark: false)); XCTAssertEqual(store.appearance, .init())
    XCTAssertFalse(store.setAppearanceFont(.content, family: "Georgia", dark: false))
    XCTAssertEqual(store.appearance, .init()); XCTAssertEqual(callbacks, 0); XCTAssertEqual(store.library.drafts["fixture"], "keep")
  }
  func testCopyUsesOnlySelectedVariantOnPrivateClipboardAndCanBeImported() throws {
    let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
    let (store, _) = store(); XCTAssertTrue(store.selectCodeTheme("github", dark: false)); XCTAssertTrue(store.selectCodeTheme("dracula", dark: true))
    let original = store.appearance
    try AppearanceThemeClipboard.copy(original, dark: true, to: pasteboard)
    let text = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertTrue(text.hasPrefix("codex-theme-v1:{")); XCTAssertFalse(text.contains("drafts")); XCTAssertFalse(text.contains("projects"))
    XCTAssertEqual(try AppearanceThemeShare.decode(text, dark: true).codeThemeId, "dracula")
    XCTAssertThrowsError(try AppearanceThemeShare.decode(text, dark: false)); XCTAssertEqual(store.appearance, original)
  }
  func testManualAccentChangesShareSourceAndResetDoesNotModifyOppositePalette() throws {
    let (store, root) = store(); XCTAssertTrue(store.selectCodeTheme("codex", dark: false))
    XCTAssertEqual(store.appearance.light.accentSource, "chatgpt"); let dark = store.appearance.dark
    XCTAssertTrue(store.setAppearanceColor("#FF9900", key: \.accent, dark: false))
    XCTAssertEqual(store.appearance.themeShare(dark: false).theme.accentSource, "custom")
    XCTAssertEqual(store.appearance.themeShare(dark: false).theme.accent, "#ff9900")
    XCTAssertEqual(store.appearance.dark, dark)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertTrue(store.setAppearanceColor(nil, key: \.accent, dark: false))
    XCTAssertNil(store.appearance.light.accentSource); XCTAssertNil(store.appearance.light.accent)
    XCTAssertEqual(store.appearance.dark, dark)
  }
  func testContentFontTracksUIUntilExplicitChoiceAndFaceResetFollowsPresetPatch() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance = appearance.settingFont(.ui, family: "Helvetica", dark: false)
    XCTAssertEqual(appearance.nativeFont(size: 14, content: true).familyName, "Helvetica")
    appearance = appearance.settingFont(.ui, family: "Georgia", dark: false)
    XCTAssertEqual(appearance.nativeFont(size: 14, content: true).familyName, "Georgia")
    appearance = appearance.settingFont(.content, family: "Menlo", dark: false)
    XCTAssertEqual(appearance.nativeFont(size: 14, content: true).familyName, "Menlo")
    XCTAssertEqual(appearance.nativeFont(size: 14).familyName, "Georgia")
    let face = AppearanceFontFace(family: "Menlo", fullName: "Menlo Bold", postscriptName: "Menlo-Bold")
    appearance = appearance.settingFont(.content, family: "Menlo", face: face, dark: false)
    XCTAssertTrue(NSFontManager.shared.traits(of: appearance.nativeFont(size: 14, content: true)).contains(.boldFontMask))
    appearance = appearance.settingFont(.content, family: nil, dark: false)
    XCTAssertNil(appearance.light.contentFace); XCTAssertEqual(appearance.nativeFont(size: 14, content: true).familyName, "Georgia")
    appearance = appearance.settingFont(.code, family: "Menlo", face: face, dark: false)
    let github = try XCTUnwrap(appearance.selectingCodeTheme("github", dark: false)); XCTAssertEqual(github.light.codeFace, face)
    let xcode = try XCTUnwrap(github.selectingCodeTheme("xcode", dark: false)); XCTAssertNil(xcode.light.codeFace)
    let restored = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(github)); XCTAssertEqual(restored, github)
  }
  func testNativeMessageUsesContentFaceAndSelectedCodeFontWithoutChangingCharacters() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance = appearance.settingFont(.ui, family: "Georgia", dark: false)
    appearance = appearance.settingFont(.content, family: "Helvetica", face: .init(family: "Helvetica", fullName: "Helvetica Bold", postscriptName: "Helvetica-Bold"), dark: false)
    appearance = appearance.settingFont(.code, family: "Menlo", dark: false)
    let text = try AttributedString(markdown: "正文 **加粗** `代码` [链接](https://example.invalid)")
    let native = LegacyMessageLinkText.attributedText(text, appearance: appearance, size: 14)
    XCTAssertEqual(native.string, String(text.characters))
    let first = try XCTUnwrap(native.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(first.familyName, "Helvetica"); XCTAssertTrue(NSFontManager.shared.traits(of: first).contains(.boldFontMask))
    let code = (native.string as NSString).range(of: "代码")
    XCTAssertEqual((native.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)?.familyName, "Menlo")
  }
  func testHiddenPageHasSixFamilyStylePairsAndNativeSelectionPersistsInItsOwnVariant() async throws {
    _ = NSApplication.shared
    let (store, root) = store(); var appearance = AppearancePreferences(); appearance.theme = "light"; store.appearance = appearance
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 2000), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store).environment(\.appAppearance, store.appearance)); window.contentView = host
    func controls(_ view: NSView) -> [SettingsPopupMenuButton.Control] { (view as? SettingsPopupMenuButton.Control).map { [$0] } ?? view.subviews.flatMap(controls) }
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
    for variant in ["浅色", "深色"] { for role in AppearanceFontRole.allCases {
      let control = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == variant + role.title })
      let style = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == variant + role.title + "样式" })
      XCTAssertEqual(control.title, role.defaultTitle); XCTAssertFalse(style.isEnabled)
    } }
    let content = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "浅色内容字体" })
    let owner = try XCTUnwrap(content.owner)
    window.makeFirstResponder(content); owner.toggle(content, keyboard: false); owner.choose("family:Menlo", button: content)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.light.contentFont, "\"Menlo\""); XCTAssertNil(store.appearance.dark.contentFont)
    XCTAssertTrue(window.firstResponder === content)
    let style = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "浅色内容字体样式" })
    XCTAssertTrue(style.isEnabled)
    let styleOwner = try XCTUnwrap(style.owner)
    styleOwner.toggle(style, keyboard: true); styleOwner.choose("face:Menlo-Bold", button: style)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.light.contentFace?.postscriptName, "Menlo-Bold")
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    owner.toggle(content, keyboard: true); owner.choose("default", button: content)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.light.contentFont, ""); XCTAssertNil(store.appearance.light.contentFace)
    XCTAssertEqual(content.title, "与界面字体相同"); XCTAssertFalse(style.isEnabled); XCTAssertFalse(window.isVisible)
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    owner.toggle(content, keyboard: false); owner.choose("family:Menlo", button: content)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.appearance.light.contentFont, ""); XCTAssertEqual(content.title, "与界面字体相同")
    XCTAssertFalse(style.isEnabled); XCTAssertNotNil(store.generalSettingsError); XCTAssertFalse(window.isVisible)
  }
  func testSearchHasIndependentFontAndThemeShareRoutesForBothVariants() {
    let fonts = Set(SettingsSearch.results(for: "字体").compactMap(\.field))
    for field in [SettingsSearchField.lightUIFont, .darkUIFont, .lightContentFont, .darkContentFont, .lightCodeFont, .darkCodeFont] { XCTAssertTrue(fonts.contains(field)); XCTAssertEqual(field.page, .appearance) }
    let share = Set(SettingsSearch.results(for: "主题导入").compactMap(\.field))
    XCTAssertTrue(share.contains(.lightThemeShare)); XCTAssertTrue(share.contains(.darkThemeShare))
  }
}
