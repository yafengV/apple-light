import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ThemeCommandMenuTests: XCTestCase {
  private func store(failing: Bool = false) throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-command-" + UUID().uuidString)
    if failing { try Data("blocked".utf8).write(to: root) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.appearance = AppearancePreferences(); store.library.appearance?.theme = "light"
    store.library.drafts["fixture"] = "keep draft"
    return (store, root)
  }
  func testRootSearchUsesCurrentPresetDescriptionAndReferenceKeywords() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance = try XCTUnwrap(appearance.selectingCodeTheme("github", dark: false))
    XCTAssertEqual(DesktopCommand.theme.group, .configure)
    XCTAssertTrue(DesktopCommand.theme.defaultBindings.isEmpty)
    XCTAssertFalse(DesktopCommand.all.contains { $0.id == "theme" }, "Theme has no global shortcut handler")
    XCTAssertEqual(ThemeCommandMenu.rootDescription(appearance), "GitHub")
    for query in ["主题", "GitHub", "appearance", "night", "preset", "颜色"] {
      XCTAssertTrue(CommandPaletteView.matchingCommands(query, git: nil, appearance: appearance).contains { $0.id == "theme" }, query)
    }
    XCTAssertFalse(ThemeCommandMenu.rootMatches("missing-command-xyz", appearance: appearance))
    XCTAssertEqual(CommandPaletteView.matchingCommands("", git: nil, appearance: appearance).filter { $0.id == "theme" }.count, 1)
  }
  func testExclusiveRowsFollowCurrentVariantAndKeepBackWhenSearchHasNoMatches() {
    let menu = ThemeCommandMenu(); var appearance = AppearancePreferences(); appearance.theme = "light"
    XCTAssertTrue(menu.rows(query: "", appearance: appearance).isEmpty)
    menu.enter()
    for (dark, count) in [(false, 16), (true, 27)] {
      appearance.theme = dark ? "dark" : "light"
      let rows = menu.rows(query: "", appearance: appearance)
      XCTAssertEqual(rows.count, count + 2)
      XCTAssertEqual(rows[0].action, .back); XCTAssertEqual(rows[1].action, .switchMode)
      XCTAssertEqual(rows[1].title, dark ? "切换为浅色主题" : "切换为深色主题")
      XCTAssertEqual(rows.dropFirst(2).map(\.title), CodeThemeCatalog.options(dark: dark).map(\.label))
      XCTAssertEqual(rows.filter(\.selected).map(\.id), ["theme:preset:codex"])
      XCTAssertTrue(rows.dropFirst(2).allSatisfy { $0.description == (dark ? "深色配色主题" : "浅色配色主题") && $0.swatch != nil })
      XCTAssertEqual(menu.rows(query: "github", appearance: appearance).map(\.id), ["theme:back", "theme:preset:github"])
      XCTAssertEqual(menu.rows(query: "missing-command-xyz", appearance: appearance).map(\.id), ["theme:back"])
      XCTAssertEqual(menu.rows(query: "night", appearance: appearance).first?.id, "theme:back")
    }
    menu.back(); XCTAssertTrue(menu.rows(query: "", appearance: appearance).isEmpty)
  }
  func testPresetCommitsOnlyActiveVariantAndClosesExactlyOnce() throws {
    let (store, root) = try store(); let menu = ThemeCommandMenu(); menu.enter()
    var original = store.appearance
    original.dark.contentFont = "Georgia"; original.dark.accent = "#123456"
    original.codeThemes.dark = "dracula"; store.library.appearance = original
    var closes = 0; var applies = 0; store.appearanceHandler = { _ in applies += 1 }
    XCTAssertTrue(menu.perform("theme:preset:github", store: store) { closes += 1 })
    XCTAssertFalse(menu.entered); XCTAssertEqual(closes, 1); XCTAssertEqual(applies, 1)
    XCTAssertEqual(store.appearance.theme, "light"); XCTAssertEqual(store.appearance.codeThemes.light, "github")
    XCTAssertEqual(store.appearance.dark, original.dark); XCTAssertEqual(store.appearance.codeThemes.dark, "dracula")
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertFalse(menu.perform("theme:preset:github", store: store) { closes += 1 }); XCTAssertEqual(closes, 1)
  }
  func testSwitchFromSystemUsesResolvedOppositeAndPreservesBothPresets() throws {
    let (store, root) = try store(); let menu = ThemeCommandMenu()
    var original = store.appearance; original.theme = "system"
    original.codeThemes = .init(light: "github", dark: "dracula"); store.library.appearance = original
    let resolvedDark = original.isDark; menu.enter()
    var closes = 0
    XCTAssertTrue(menu.perform("theme:switch", store: store) { closes += 1 })
    XCTAssertEqual(store.appearance.theme, resolvedDark ? "light" : "dark")
    XCTAssertEqual(store.appearance.codeThemes, original.codeThemes)
    XCTAssertEqual(store.appearance.light, original.light); XCTAssertEqual(store.appearance.dark, original.dark)
    XCTAssertEqual(closes, 1); XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
  }
  func testDarkPresetUsesOnlyDarkPatchAndReappliesEvenWhenSelectedIDIsUnchanged() throws {
    let (store, _) = try store(); store.library.appearance?.theme = "dark"
    let menu = ThemeCommandMenu(); menu.enter()
    let originalLight = store.appearance.light
    XCTAssertTrue(menu.perform("theme:preset:dracula", store: store) {})
    XCTAssertEqual(store.appearance.codeThemes.dark, "dracula"); XCTAssertEqual(store.appearance.theme, "dark")
    XCTAssertEqual(store.appearance.light, originalLight); XCTAssertEqual(store.appearance.codeThemes.light, "codex")
    let presetAccent = store.appearance.dark.accent
    XCTAssertTrue(store.setAppearanceColor("#123456", key: \.accent, dark: true))
    menu.enter(); var closes = 0
    XCTAssertTrue(menu.perform("theme:preset:dracula", store: store) { closes += 1 })
    XCTAssertEqual(store.appearance.dark.accent, presetAccent); XCTAssertEqual(closes, 1)
    XCTAssertNil(menu.selectedID)
  }
  func testBackDoesNotSaveDismissOrApplyAndRemovedVariantCannotExecute() throws {
    let (store, root) = try store(); let menu = ThemeCommandMenu(); menu.enter()
    var closes = 0
    XCTAssertFalse(menu.perform("theme:preset:dracula", store: store) { closes += 1 })
    XCTAssertTrue(menu.entered)
    XCTAssertTrue(menu.perform("theme:back", store: store) { closes += 1 })
    XCTAssertEqual(closes, 0); XCTAssertFalse(menu.entered)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path))
    menu.enter(); store.library.appearance?.theme = "dark"
    XCTAssertFalse(menu.perform("theme:preset:proof", store: store) { closes += 1 })
    XCTAssertTrue(menu.entered); XCTAssertEqual(closes, 0)
  }
  func testFailureClosesMenuButRetainsAppearanceDraftAndApplyState() throws {
    let (store, _) = try store(failing: true); let menu = ThemeCommandMenu()
    let original = store.appearance; var applies = 0; var closes = 0
    store.appearanceHandler = { _ in applies += 1 }
    for id in ["theme:preset:github", "theme:switch"] {
      menu.enter(); XCTAssertTrue(menu.perform(id, store: store) { closes += 1 })
      XCTAssertFalse(menu.entered); XCTAssertEqual(store.appearance, original); XCTAssertEqual(applies, 0)
      XCTAssertNotNil(store.generalSettingsError); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    }
    XCTAssertEqual(closes, 2)
  }
  func testBorderUsesSRGBMixAndPreviewUsesPresetSeedRatherThanManualColors() throws {
    let menu = ThemeCommandMenu(); menu.enter(); var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.accent = "#ffffff"; appearance.light.background = "#123456"
    let row = try XCTUnwrap(menu.rows(query: "github", appearance: appearance).last)
    let swatch = try XCTUnwrap(row.swatch)
    let seed = try XCTUnwrap(CodeThemeCatalog.preset("github", dark: false)?.variant(dark: false)?.seed)
    XCTAssertEqual(swatch.accent, seed.accent); XCTAssertEqual(swatch.background, seed.surface)
    let mix = SettingsMenuSwatch(accent: "#00ff00", foreground: "#000000", background: "#ffffff").borderColor
    XCTAssertEqual(mix.redComponent, 0.84, accuracy: 0.00001)
    XCTAssertEqual(mix.greenComponent, 0.84, accuracy: 0.00001)
    XCTAssertEqual(mix.blueComponent, 0.84, accuracy: 0.00001)
    let renderer = ImageRenderer(content: ThemeColorSwatch(swatch: swatch))
    XCTAssertEqual(try XCTUnwrap(renderer.nsImage).size, .init(width: 24, height: 24))
  }
  func testHiddenMainCommandKeyboardSwitchKeepsSettingsAndDraft() async throws {
    let (store, _) = try store(); store.destination = .settings; store.showingCommands = true
    let menu = ThemeCommandMenu(); menu.enter()
    let (window, host) = host(CommandPaletteView(store: store, themeMenu: menu)); defer { window.close() }
    try await settle(host)
    let bridge = try XCTUnwrap(findAnchor(host)?.coordinator)
    XCTAssertTrue(menu.entered)
    bridge.action(.move(1))
    XCTAssertEqual(menu.selectedID, "theme:switch", "The installed callback must select the next row immediately")
    try await settle(host)
    XCTAssertEqual(menu.selectedID, "theme:switch")
    bridge.action(.submit); try await settle(host)
    XCTAssertEqual(store.appearance.theme, "dark"); XCTAssertNil(store.presentedOverlay)
    XCTAssertEqual(store.destination, .settings); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertFalse(window.isVisible)
  }
  func testHiddenAlternateCommandKeyboardDismissesOnlyOriginatingContext() async throws {
    let (store, _) = try store(); store.showingCommands = true
    let menu = ThemeCommandMenu(); menu.enter(); var contextOpen = true; var executes = 0
    let context = SearchDialogContext(currentTaskID: "alternate", commandEnabled: { _ in false },
      performCommand: { _ in executes += 1 }, canSelectTask: { _ in false }, navigate: { _ in }, cancel: { contextOpen = false })
    let (window, host) = host(CommandPaletteView(store: store, context: context, themeMenu: menu)); defer { window.close() }
    try await settle(host)
    let bridge = try XCTUnwrap(findAnchor(host)?.coordinator)
    bridge.action(.move(2)); try await settle(host) // First color preset after Back and Switch.
    XCTAssertEqual(menu.selectedID, "theme:preset:absolutely")
    bridge.action(.submit); try await settle(host)
    XCTAssertFalse(contextOpen); XCTAssertFalse(menu.entered); XCTAssertEqual(executes, 0)
    XCTAssertEqual(store.presentedOverlay, .commands); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertFalse(window.isVisible)
  }
  func testHiddenBackAndEscapeKeepWorkspaceAndResetDrillIn() async throws {
    let (store, _) = try store(); store.showingCommands = true
    let menu = ThemeCommandMenu(); menu.enter()
    let (window, host) = host(CommandPaletteView(store: store, themeMenu: menu)); defer { window.close() }
    try await settle(host)
    let bridge = try XCTUnwrap(findAnchor(host)?.coordinator)
    bridge.action(.submit); try await settle(host)
    XCTAssertFalse(menu.entered); XCTAssertEqual(store.presentedOverlay, .commands)
    menu.enter(); try await settle(host)
    bridge.action(.move(1)); try await settle(host)
    XCTAssertEqual(menu.selectedID, "theme:switch")
    bridge.action(.cancel); try await settle(host)
    XCTAssertFalse(menu.entered); XCTAssertNil(menu.selectedID); XCTAssertNil(store.presentedOverlay)
    XCTAssertEqual(store.appearance.theme, "light"); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertFalse(window.isVisible)
  }
  private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    for _ in 0..<5 { host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
  }
  private func findAnchor(_ view: NSView) -> SearchDialogKeyboardBridge.Anchor? {
    if let anchor = view as? SearchDialogKeyboardBridge.Anchor { return anchor }
    return view.subviews.compactMap(findAnchor).first
  }
}
