import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceAccentPickerTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Option: Decodable { let id: String; let title: String; let messageKey: String; let disabled: Bool; let selected: Bool; let swatch: String? }
    struct Case: Decodable {
      let source: String?; let account: String?; let dark: Bool; let pending: Bool; let title: String; let messageKey: String; let selectedID: String
      let customLabel: String?; let customValue: String?; let triggerDisabled: Bool; let customSelectionValue: String; let options: [Option]
    }
    let settingsSHA256: String; let initialSHA256: String; let messagesSHA256: String; let translationSHA256: String; let cssSHA256: String
    let options: [String]; let cases: [Case]; let css: String; let itemClasses: String
  }
  private func reference() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "accent_menu_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  func test108ActualReferenceSelectionsLabelsSwatchesAndNullAccountOptions() throws {
    let f = try reference(); XCTAssertEqual(f.cases.count, 108)
    XCTAssertEqual(f.settingsSHA256, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    XCTAssertEqual(f.initialSHA256, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(f.messagesSHA256, "f9738c812790d8fb4ef17374b67be2e7b59556208357bc996ab1a5f20251e7ea")
    XCTAssertEqual(f.translationSHA256, "43e8401d13c6b4a2554c2263406a2bc67a5106ec6b277aea2f19d3ce978553c6")
    XCTAssertEqual(f.cssSHA256, "d5573a93b11a7826bf232e754d1b6353777d01c0bc067174f1701743537f9eea")
    XCTAssertEqual(AppearanceAccountAccent.allCases.map(\.rawValue), f.options)
    let (store, _) = makeStore()
    for item in f.cases {
      let selection = AppearanceAccentSelection(source: item.source, accountAccent: item.account.flatMap(AppearanceAccountAccent.init(rawValue:)), dark: item.dark)
      XCTAssertEqual(selection.title, item.title); XCTAssertEqual(selection.messageKey, item.messageKey); XCTAssertEqual(selection.selectedID, item.selectedID)
      XCTAssertEqual(selection.isCustom ? selection.customLabel : nil, item.customLabel)
      XCTAssertEqual(item.customSelectionValue, "#123456"); XCTAssertEqual(item.triggerDisabled, item.pending)
      for option in item.options where option.id != "custom" {
        let account = try XCTUnwrap(AppearanceAccountAccent(rawValue: option.id))
        XCTAssertEqual(account.title(dark: item.dark), option.title); XCTAssertEqual(account.messageKey(dark: item.dark), option.messageKey)
        XCTAssertEqual(account.swatch(dark: item.dark).hex, option.swatch)
      }
      // Account-present samples verify display only. Product auth is independent API.
      if item.account == nil {
        let menu = AppearanceAccentMenuState(); menu.open(dark: item.dark, keyboard: false, store: store)
        XCTAssertEqual(menu.options.map(\.id), item.options.map(\.id)); XCTAssertEqual(menu.options.map(\.title), item.options.map(\.title))
        XCTAssertEqual(menu.options.map { !$0.enabled }, item.options.map(\.disabled)); XCTAssertEqual(menu.options.map { $0.swatch?.hex }, item.options.map(\.swatch))
      }
    }
  }
  func testActualElectronCSSBodyPaddingAndLineHeightDetermineRowGeometry() async throws {
    let f = try reference(); let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration); XCTAssertNil(web.window)
    let output = try await web.callAsyncJavaScript(#"""
      document.documentElement.dataset.codexWindowType='electron';
      const style=document.createElement('style');style.textContent=css;document.head.appendChild(style);
      const item=document.createElement('div');item.className=classes;item.style.width='212px';item.textContent='自定义';document.body.appendChild(item);
      const c=getComputedStyle(item);return [parseFloat(c.fontSize),parseFloat(c.lineHeight),parseFloat(c.paddingTop),parseFloat(c.paddingBottom),parseFloat(c.paddingLeft),item.getBoundingClientRect().height];
      """#, arguments: ["css": f.css, "classes": f.itemClasses], in: nil, contentWorld: .defaultClient)
    let values = try XCTUnwrap(output as? [Double]); XCTAssertEqual(values.count, 6)
    XCTAssertEqual(values[0], 13); XCTAssertEqual(values[1], 13 * (1.25 / 0.875), accuracy: 0.001)
    XCTAssertEqual(Array(values[2...4]), [5, 5, 8])
    XCTAssertEqual(AppearanceAccentMenuState.rowHeight(fontSize: 13), values[1] + values[2] + values[3], accuracy: 0.001)
    // WebKit rounds this inline line box to 18px, despite computed 18.5714px.
    // Verify that observation separately. It is not evidence of Chromium's paint.
    XCTAssertEqual(values[5], 28)
    XCTAssertNil(web.window)
  }
  func testKeyboardSkipsDisabledChoicesAndTypeaheadSpaceExpires() {
    let (store, _) = makeStore(); let menu = AppearanceAccentMenuState(); menu.open(dark: true, keyboard: false, store: store)
    XCTAssertNil(menu.highlightedID); menu.hover("blue"); XCTAssertNil(menu.highlightedID); menu.type("蓝", now: 1); XCTAssertNil(menu.highlightedID)
    menu.type("自", now: 2.1); XCTAssertEqual(menu.highlightedID, "custom"); menu.type("定", now: 2.2)
    XCTAssertFalse(menu.space(now: 2.3)); XCTAssertTrue(menu.space(now: 3.4))
    menu.hover(nil); menu.move(-1); XCTAssertEqual(menu.highlightedID, "custom")
    menu.edge(last: false); menu.move(-1); menu.edge(last: true); menu.move(1); XCTAssertEqual(menu.highlightedID, "custom")
    let before = store.appearance; XCTAssertFalse(menu.choose("blue", store: store)); XCTAssertFalse(menu.choose("unknown", store: store)); XCTAssertEqual(store.appearance, before)
    menu.dismiss(); menu.type("自", now: 5); menu.move(1); menu.hover("custom"); XCTAssertNil(menu.highlightedID); XCTAssertFalse(menu.space(now: 5))
  }
  func testCustomTransitionPreservesPresetOtherFieldsAndOppositeSideAndRepeatIsNoop() throws {
    let (store, root) = makeStore(); XCTAssertTrue(store.selectCodeTheme("codex", dark: true))
    var appearance = store.appearance; appearance.dark.accent = "#123456"; appearance.dark.uiFont = "Georgia"; appearance.dark.foreground = "#ABCDEF"
    XCTAssertTrue(store.commitAppearance(appearance)); let before = store.appearance
    let menu = AppearanceAccentMenuState(); menu.open(dark: true, keyboard: true, store: store); XCTAssertTrue(menu.choose("custom", store: store))
    var expected = before; expected.dark.accentSource = "custom"
    XCTAssertEqual(store.appearance, expected); XCTAssertEqual(store.appearance.codeThemes, before.codeThemes); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    let saved = try Data(contentsOf: root.appendingPathComponent("workspace.json")); menu.open(dark: true, keyboard: true, store: store)
    XCTAssertTrue(menu.choose("custom", store: store)); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), saved); XCTAssertFalse(menu.choose("custom", store: store))
  }
  func testFailedSaveAndFreshAvailabilityDoNotChangeSavedSource() throws {
    let (store, root) = makeStore(); XCTAssertTrue(store.selectCodeTheme("codex", dark: false)); let before = store.appearance
    let menu = AppearanceAccentMenuState(); store.libraryLoaded = false; menu.open(dark: false, keyboard: true, store: store); XCTAssertFalse(menu.presented)
    store.libraryLoaded = true; store.restoringLibrary = true; menu.open(dark: false, keyboard: true, store: store); XCTAssertFalse(menu.presented)
    store.restoringLibrary = false; menu.open(dark: false, keyboard: true, store: store); store.libraryLoaded = false
    XCTAssertFalse(menu.choose("custom", store: store)); XCTAssertEqual(store.appearance, before)
    store.libraryLoaded = true; store.restoringLibrary = true; XCTAssertFalse(menu.choose("custom", store: store)); store.restoringLibrary = false
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    XCTAssertTrue(menu.choose("custom", store: store)); XCTAssertFalse(menu.presented); XCTAssertEqual(store.appearance, before); XCTAssertNotNil(store.generalSettingsError)
  }
  func testHiddenPickerCustomVisibilitySameWindowMenuKeyboardAndImmediateColorSave() async throws {
    let (store, root) = makeStore(); XCTAssertTrue(store.selectCodeTheme("codex", dark: false)); let (window, host) = try await surface(store); defer { window.close() }
    let button = try XCTUnwrap(find(host, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "浅色强调色" }); let owner = try XCTUnwrap(button.owner)
    XCTAssertEqual(button.title, "默认"); XCTAssertEqual(button.frame.size, .init(width: 144, height: 28)); XCTAssertEqual(button.font?.pointSize, 13)
    XCTAssertNil(find(host, as: AppearanceColorInput.Control.self).first { $0.field.accessibilityLabel() == "浅色模式下的自定义强调色" })
    owner.toggle(button, keyboard: true); try await settle(host); let popup = try XCTUnwrap(owner.popup); let menu = try XCTUnwrap(owner.parent.menu as? AppearanceAccentMenuState)
    XCTAssertTrue(popup.window === window); XCTAssertEqual(popup.frame.width, 220); XCTAssertEqual(popup.frame.height, menu.height(fontSize: 13), accuracy: 0.000001)
    XCTAssertEqual(menu.options.filter(\.enabled).map(\.id), ["custom"]); XCTAssertEqual(menu.highlightedID, "custom"); XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    owner.choose("blue", button: button); XCTAssertTrue(menu.presented); XCTAssertEqual(button.title, "默认")
    XCTAssertTrue(owner.handle(try key(48, window), button: button)); XCTAssertTrue(menu.presented)
    XCTAssertTrue(owner.handle(try key(53, window), button: button)); try await settle(host); XCTAssertTrue(window.firstResponder === button)
    owner.toggle(button, keyboard: true); XCTAssertTrue(owner.handle(try key(36, window), button: button)); try await settle(host)
    XCTAssertEqual(button.title, "自定义"); XCTAssertTrue(window.firstResponder === button); XCTAssertNil(owner.popup)
    let color = try XCTUnwrap(find(host, as: AppearanceColorInput.Control.self).first { $0.field.accessibilityLabel() == "浅色模式下的自定义强调色" })
    XCTAssertTrue(window.makeFirstResponder(color.field)); let editor = try XCTUnwrap(color.field.currentEditor() as? NSTextView)
    editor.string = "#ab12ef"; color.field.stringValue = editor.string; color.owner?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: color.field)); try await settle(host)
    XCTAssertEqual(store.appearance.light.accent, "#AB12EF"); XCTAssertEqual(store.appearance.light.accentSource, "custom"); XCTAssertNil(store.appearance.dark.accent)
    XCTAssertTrue(window.firstResponder === editor); XCTAssertTrue(find(host, as: AppearanceColorInput.Control.self).contains { $0 === color })
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance); XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  func testHiddenFreshAvailabilityFailureFocusAndMutualExclusion() async throws {
    let (store, root) = makeStore(); XCTAssertTrue(store.selectCodeTheme("codex", dark: false)); let (window, host) = try await surface(store); defer { window.close() }
    let button = try XCTUnwrap(find(host, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "浅色强调色" }); let owner = try XCTUnwrap(button.owner)
    store.libraryLoaded = false; owner.toggle(button, keyboard: true); XCTAssertNil(owner.popup); store.libraryLoaded = true
    owner.toggle(button, keyboard: true); try await settle(host); let before = store.appearance
    store.libraryLoaded = false; owner.choose("custom", button: button); XCTAssertEqual(store.appearance, before); store.libraryLoaded = true
    let font = try XCTUnwrap(find(host, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "浅色界面字体" })
    try XCTUnwrap(font.owner).toggle(font, keyboard: true); try await settle(host); XCTAssertNil(owner.popup)
    let darkColor = try XCTUnwrap(find(host, as: AppearanceColorInput.Control.self).first { $0.field.accessibilityLabel() == "深色自定义强调色" })
    try XCTUnwrap(darkColor.owner).toggle(darkColor); try await settle(host); XCTAssertNil(font.owner?.popup); XCTAssertNotNil(darkColor.owner?.popup)
    owner.toggle(button, keyboard: true); try await settle(host); XCTAssertNil(darkColor.owner?.popup)
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    owner.choose("custom", button: button); try await settle(host); XCTAssertNil(owner.popup); XCTAssertEqual(button.title, "默认"); XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(store.appearance, before); XCTAssertNotNil(store.generalSettingsError); XCTAssertFalse(window.isVisible)
  }
  func testHiddenDetachedAndStaleCallbacksCannotChangeSource() async throws {
    let (store, _) = makeStore(); XCTAssertTrue(store.selectCodeTheme("codex", dark: false)); let (window, host) = try await surface(store); defer { window.close() }
    let button = try XCTUnwrap(find(host, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "浅色强调色" }); let owner = try XCTUnwrap(button.owner)
    owner.toggle(button, keyboard: true); try await settle(host); let saved = store.appearance
    button.removeFromSuperview(); owner.choose("custom", button: button); XCTAssertEqual(store.appearance, saved); XCTAssertNil(owner.popup)
    host.rootView = AnyView(Text("unmounted")); try await settle(host); owner.choose("custom", button: button); XCTAssertEqual(store.appearance, saved); XCTAssertFalse(window.isVisible)
  }
  func testHiddenMenusRemainIndependentAcrossWindowsAndUseScaledFontGeometry() async throws {
    let (store, _) = makeStore(); var appearance = store.appearance; appearance.uiSize = 16
    XCTAssertTrue(store.commitAppearance(appearance))
    let (first, firstHost) = try await surface(store); let (second, secondHost) = try await surface(store)
    defer { first.close(); second.close() }
    let a = try XCTUnwrap(find(firstHost, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "浅色强调色" })
    let b = try XCTUnwrap(find(secondHost, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "深色强调色" })
    let aOwner = try XCTUnwrap(a.owner); let bOwner = try XCTUnwrap(b.owner)
    aOwner.toggle(a, keyboard: false); bOwner.toggle(b, keyboard: true); try await settle(firstHost); try await settle(secondHost)
    XCTAssertTrue(aOwner.popup?.window === first); XCTAssertTrue(bOwner.popup?.window === second)
    XCTAssertEqual(a.font?.pointSize, 15)
    let state = try XCTUnwrap(aOwner.parent.menu as? AppearanceAccentMenuState)
    XCTAssertEqual(try XCTUnwrap(aOwner.popup).frame.height, state.height(fontSize: 15), accuracy: 0.000001)
    XCTAssertTrue(bOwner.handle(try key(53, second), button: b)); try await settle(secondHost)
    XCTAssertNotNil(aOwner.popup); XCTAssertNil(bOwner.popup); XCTAssertTrue(second.firstResponder === b)
    XCTAssertFalse(first.isVisible); XCTAssertFalse(second.isVisible)
  }
  private func makeStore() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("accent-picker-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings; store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  private struct Surface: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
      VStack(spacing: 24) {
        AppearanceAccentPicker(store: store, dark: false); AppearanceAccentPicker(store: store, dark: true)
        AppearanceFontPicker(store: store, role: .ui, dark: false, catalog: AppearanceFontCatalogSource(families: nil))
      }.frame(width: 700).frame(width: 850, height: 900).environment(\.appAppearance, store.appearance)
    }
  }
  private func surface(_ store: WorkspaceStore) async throws -> (NSWindow, NSHostingView<AnyView>) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; let host = NSHostingView(rootView: AnyView(Surface(store: store))); window.contentView = host
    try await settle(host); XCTAssertFalse(window.isVisible); return (window, host)
  }
  private func find<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, as: type) } }
  private func key(_ code: UInt16, _ window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
  }
}
