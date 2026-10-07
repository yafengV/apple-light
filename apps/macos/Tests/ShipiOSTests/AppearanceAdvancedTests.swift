import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceAdvancedTests: XCTestCase {
  func testCurrentDistributionPresentationAndFontControlSplit() throws {
    let fixture = try reference()
    XCTAssertEqual(fixture["version"] as? String, "26.930.51102")
    let hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String: String])
    XCTAssertEqual(hashes["settings"], "91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535")
    XCTAssertEqual(hashes["app"], "22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3")
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 24)
    for sample in cases {
      let presentation = AppearancePagePresentation(advancedExpanded: try XCTUnwrap(sample["advanced"] as? Bool))
      presentation.separateModes = try XCTUnwrap(sample["separate"] as? Bool)
      XCTAssertEqual(presentation.variants(theme: try XCTUnwrap(sample["mode"] as? String),
        systemDark: try XCTUnwrap(sample["systemDark"] as? Bool)).map(\.rawValue), sample["variants"] as? [String])
      XCTAssertEqual(sample["advancedMounted"] as? Bool, presentation.advancedExpanded)
      XCTAssertEqual(sample["previewMounted"] as? Bool, false)
      XCTAssertEqual((sample["visualFonts"] as? [[String: Any]])?.compactMap { $0["controls"] as? String }, ["family"])
      XCTAssertEqual((sample["advancedFonts"] as? [[String: Any]])?.compactMap { $0["controls"] as? String }, ["style", "both", "both"])
    }
  }

  func testCurrentResetPreservesVisualStyleAndClearsBothAdvancedPalettes() throws {
    let resets = try XCTUnwrap(reference()["resets"] as? [[String: Any]])
    XCTAssertEqual(resets.count, 4)
    var value = AppearancePreferences()
    value.theme = "dark"; value.uiFont = "legacy UI"; value.codeFont = "legacy code"
    value.uiSize = 17.5; value.codeSize = 18; value.reduceMotion = .on
    value.diffMarkerStyle = .symbols; value.usePointerCursors = true
    for sample in resets where sample["supported"] as? Bool == true {
      let dark = sample["variant"] as? String == "dark"
      let initial = try XCTUnwrap(sample["initial"] as? [String: Any])
      var palette = dark ? value.dark : value.light
      palette.accent = initial["accent"] as? String; palette.background = initial["surface"] as? String
      palette.foreground = initial["ink"] as? String; palette.accentSource = "custom"
      palette.uiFont = "Menlo"; palette.contentFont = "Georgia"; palette.codeFont = "Monaco"
      let face = AppearanceFontFace(family: "Menlo", fullName: "Menlo Bold", postscriptName: "Menlo-Bold")
      palette.uiFace = face; palette.codeFace = face; palette.contentFace = face
      palette.contrast = 70; palette.translucentSidebar = false; palette.skill = "#987654"
      if dark { value.dark = palette } else { value.light = palette }
    }
    let reset = value.resettingAdvanced()
    XCTAssertTrue(value.hasAdvancedChanges); XCTAssertFalse(reset.hasAdvancedChanges)
    XCTAssertEqual(reset.theme, value.theme); XCTAssertEqual(reset.uiFont, value.uiFont)
    XCTAssertEqual(reset.codeThemes, value.codeThemes); XCTAssertEqual(reset.uiSize, 14); XCTAssertEqual(reset.codeSize, 12)
    XCTAssertEqual(reset.codeFont, ""); XCTAssertEqual(reset.reduceMotion, .system)
    XCTAssertEqual(reset.diffMarkerStyle, .color); XCTAssertFalse(reset.usePointerCursors)
    for sample in resets where sample["supported"] as? Bool == true {
      let dark = sample["variant"] as? String == "dark", palette = dark ? reset.dark : reset.light
      let result = try XCTUnwrap(sample["result"] as? [String: Any]), fonts = try XCTUnwrap(result["fonts"] as? [String: Any])
      XCTAssertEqual(palette.contrast, result["contrast"] as? Double)
      XCTAssertEqual(!palette.translucentSidebar, result["opaqueWindows"] as? Bool)
      XCTAssertEqual(palette.uiFont, fonts["ui"] as? String)
      XCTAssertTrue(fonts["code"] is NSNull); XCTAssertTrue(fonts["content"] is NSNull)
      XCTAssertNil(palette.codeFont); XCTAssertNil(palette.contentFont)
      XCTAssertNil(palette.uiFace); XCTAssertNil(palette.codeFace); XCTAssertNil(palette.contentFace)
      XCTAssertEqual(palette.accent, result["accent"] as? String)
      XCTAssertEqual(palette.background, result["surface"] as? String)
      XCTAssertEqual(palette.foreground, result["ink"] as? String)
      XCTAssertEqual(palette.skill, "#987654")
    }
    var visualOnly = AppearancePreferences(); visualOnly.theme = "dark"; visualOnly.light.uiFont = "Menlo"
    visualOnly.light.background = "#123456"; visualOnly.dark.codeFont = ""; visualOnly.dark.contentFont = ""
    XCTAssertFalse(visualOnly.hasAdvancedChanges)
  }

  func testNativeDisclosureSeparateModesCollapseAndResetWithoutChangingVisualValues() async throws {
    let f = try await fixture(); defer { f.window.close() }
    XCTAssertEqual(find(f.host, AppearanceColorInput.Control.self).count, 3)
    XCTAssertEqual(find(f.host, AppearanceContrastSlider.Control.self).count, 0)
    XCTAssertEqual(find(f.host, AppearanceFontSizeInput.Control.self).count, 0)
    XCTAssertEqual(fontLabels(f.host), ["浅色界面字体"])
    XCTAssertEqual(find(f.host, WKWebView.self).count, 0)
    let advanced = try action("高级", f.host)
    XCTAssertEqual(advanced.accessibilityValue() as? String, "已折叠")
    XCTAssertTrue(advanced.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertTrue(f.presentation.advancedExpanded)
    XCTAssertEqual(find(f.host, AppearanceContrastSlider.Control.self).count, 1)
    XCTAssertEqual(find(f.host, AppearanceFontSizeInput.Control.self).count, 2)
    XCTAssertEqual(fontLabels(f.host).count, 6)
    let initial = f.store.appearance
    f.presentation.separateModes = true; try await settle(f.host)
    XCTAssertEqual(f.store.appearance, initial)
    XCTAssertEqual(find(f.host, AppearanceColorInput.Control.self).count, 6)
    XCTAssertEqual(find(f.host, AppearanceContrastSlider.Control.self).count, 2)
    XCTAssertEqual(fontLabels(f.host).count, 12)
    let content = try XCTUnwrap(find(f.host, SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "深色内容字体" })
    XCTAssertTrue(content.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertTrue(SettingsPopupMenuButton.hasOpenMenu(in: f.window))
    XCTAssertTrue(advanced.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertFalse(SettingsPopupMenuButton.hasOpenMenu(in: f.window))
    XCTAssertEqual(find(f.host, AppearanceContrastSlider.Control.self).count, 0)
    XCTAssertEqual(fontLabels(f.host).count, 2)
    XCTAssertTrue(try action("重置高级外观设置", f.host).accessibilityPerformPress()); try await settle(f.host)
    XCTAssertFalse(f.presentation.separateModes); XCTAssertFalse(f.presentation.advancedExpanded)
    XCTAssertEqual(f.store.appearance, initial); XCTAssertEqual(f.store.library.drafts["fixture"], "keep")
    XCTAssertFalse(f.window.isVisible)
  }

  func testResetSaveFailureKeepsPreferencesThenRetryPersistsBothPalettes() async throws {
    let f = try await fixture(); defer { f.window.close() }
    var value = f.store.appearance; value.uiSize = 18; value.light.uiFont = "Menlo"
    value.light.uiFace = .init(family: "Menlo", fullName: "Menlo Bold", postscriptName: "Menlo-Bold")
    value.dark.contrast = 80; value.dark.codeFont = "Monaco"; value.dark.accent = "#123456"
    XCTAssertTrue(f.store.commitAppearance(value)); try await settle(f.host)
    let file = f.root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    f.presentation.separateModes = true; try await settle(f.host)
    XCTAssertTrue(try action("重置高级外观设置", f.host).accessibilityPerformPress()); try await settle(f.host)
    XCTAssertEqual(f.store.appearance, value.normalized()); XCTAssertNotNil(f.store.generalSettingsError)
    XCTAssertFalse(f.presentation.separateModes)
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(try action("重置高级外观设置", f.host).accessibilityPerformPress()); try await settle(f.host)
    XCTAssertFalse(f.store.appearance.hasAdvancedChanges)
    XCTAssertEqual(f.store.appearance.light.uiFont, "Menlo"); XCTAssertEqual(f.store.appearance.dark.accent, "#123456")
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).appearance, f.store.appearance)
    XCTAssertEqual(f.store.library.drafts["fixture"], "keep")
  }

  func testSearchEntryExpandsAdvancedAndDoesNotChangeMode() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.store.revealSetting(.init(page: .appearance, field: .codeFontSize))
    let host = NSHostingView(rootView: AppearanceSettingsView(store: f.store))
    f.window.contentView = host; try await settle(host)
    XCTAssertEqual(find(host, AppearanceFontSizeInput.Control.self).count, 2)
    XCTAssertEqual(find(host, AppearanceColorInput.Control.self).count, 3)
    XCTAssertEqual(f.store.appearance.theme, "light")
    XCTAssertEqual(SettingsSearch.results(for: "深色界面字体", appearanceTheme: "light").compactMap(\.field), [])
    XCTAssertTrue(SettingsSearch.results(for: "界面字体样式", appearanceTheme: "dark").contains { $0.field == .darkUIFontStyle })
  }

  func testSeparateModesImportsInactivePaletteWithoutSwitchingModeAndInvalidatesOnModeChange() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.presentation.separateModes = true; try await settle(f.host)
    let initialLight = f.store.appearance.light
    XCTAssertTrue(try action("导入深色主题", f.host).accessibilityPerformPress())
    let session = try XCTUnwrap(f.store.appearanceThemeImport)
    XCTAssertTrue(f.store.canEditAppearanceImport(session))
    var imported = f.store.appearance; imported.dark.contrast = 77
    session.value = try imported.themeShare(dark: true).encoded()
    XCTAssertTrue(f.store.submitAppearanceImport(session))
    XCTAssertEqual(f.store.appearance.theme, "light"); XCTAssertEqual(f.store.appearance.light, initialLight)
    XCTAssertEqual(f.store.appearance.dark.contrast, 77)
    XCTAssertEqual(try WorkspaceLibrary.load(from: f.root.appendingPathComponent("workspace.json")).appearance, f.store.appearance)
    try await settle(f.host)
    XCTAssertTrue(try action("导入深色主题", f.host).accessibilityPerformPress())
    let obsolete = try XCTUnwrap(f.store.appearanceThemeImport)
    var next = f.store.appearance; next.theme = "system"; XCTAssertTrue(f.store.commitAppearance(next))
    XCTAssertNil(f.store.appearanceThemeImport); XCTAssertFalse(f.store.canEditAppearanceImport(obsolete))
    XCTAssertEqual(f.store.library.drafts["fixture"], "keep")
  }

  func testActualSettingsContainerRemountsAppearanceAcrossPagesExitAndSearch() async throws {
    let f = try await fixture(); defer { f.window.close() }
    let host = NSHostingView(rootView: RuntimeSettingsView(store: f.store))
    f.window.contentView = host; try await settle(host)
    XCTAssertTrue(find(host, AppearanceFontSizeInput.Control.self).isEmpty)
    XCTAssertTrue(try action("高级", host).accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(find(host, AppearanceFontSizeInput.Control.self).count, 2)
    f.store.requestSettingsPage(.profile); try await settle(host)
    f.store.requestSettingsPage(.appearance); try await settle(host)
    XCTAssertTrue(find(host, AppearanceFontSizeInput.Control.self).isEmpty)
    f.store.revealSetting(.init(page: .appearance, field: .codeFontSize)); try await settle(host)
    XCTAssertEqual(find(host, AppearanceFontSizeInput.Control.self).count, 2)
    f.store.closeSettings(); try await settle(host)
    f.store.openSettings(.appearance); try await settle(host)
    XCTAssertTrue(find(host, AppearanceFontSizeInput.Control.self).isEmpty)
    XCTAssertEqual(f.store.library.drafts["fixture"], "keep")
    XCTAssertFalse(f.window.isVisible)
  }

  private struct Fixture { let root: URL; let store: WorkspaceStore; let presentation: AppearancePagePresentation; let window: NSWindow; let host: NSView }
  private func fixture() async throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-advanced-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.destination = .settings; store.settingsPage = .appearance; store.library.drafts["fixture"] = "keep"
    var value = store.appearance; value.theme = "light"; XCTAssertTrue(store.commitAppearance(value))
    await AppearanceFontCatalogSource.shared.load()
    let presentation = AppearancePagePresentation()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 2600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store, presentation: presentation))
    window.contentView = host; try await settle(host)
    return .init(root: root, store: store, presentation: presentation, window: window, host: host)
  }
  private func reference() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_advanced_reference_646", withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  private func fontLabels(_ host: NSView) -> Set<String> {
    Set(find(host, SettingsPopupMenuButton.Control.self).compactMap { $0.accessibilityLabel() }.filter { $0.contains("字体") })
  }
  private func action(_ label: String, _ host: NSView) throws -> AppearanceActionButton.Control {
    try XCTUnwrap(find(host, AppearanceActionButton.Control.self).first { $0.accessibilityLabel() == label })
  }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(160)); view.layoutSubtreeIfNeeded() }
}
