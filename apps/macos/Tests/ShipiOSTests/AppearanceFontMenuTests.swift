import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceFontMenuTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Family: Decodable {
      struct Face: Decodable { let family: String; let fullName: String; let postscriptName: String; let styleName: String; let isMonospaced: Bool }
      let family: String; let faces: [Face]
      var native: AppearanceFontCatalog.Family { .init(name: family, faces: faces.map { .init(value: .init(family: $0.family, fullName: $0.fullName, postscriptName: $0.postscriptName), style: $0.styleName, weight: 5, italic: false, monospaced: $0.isMonospaced) }) }
    }
    struct Parser: Decodable { let value: String?; let first: String?; let display: String? }
    struct Case: Decodable {
      let value: String?; let face: AppearanceFontFace?; let role: String; let family: String?; let postscript: String?
      let title: String; let selectedDefault: Bool; let styleEnabled: Bool; let familyOptions: [String]
    }
    let parserSHA256: String; let settingsSHA256: String; let families: [Family]; let parsers: [Parser]; let cases: [Case]
  }
  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "font_menu_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  private func store() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-menu-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings
    store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  func testFirstFamilyParserMatches51DistributedJavaScriptCases() throws {
    let fixture = try fixture(); XCTAssertEqual(fixture.parsers.count, 51)
    XCTAssertEqual(fixture.parserSHA256, "534fde2365b7c3535443a58e3dceac3015b12b2c18c3778967b28f7299ae0725")
    for item in fixture.parsers {
      XCTAssertEqual(AppearanceFontFamily.first(item.value), item.first, item.value ?? "nil")
      XCTAssertEqual(AppearanceFontFamily.displayName(item.value), item.display, item.value ?? "nil")
    }
    for name in ["Font, Comma", "Quote \" font", "Back\\slash", "Emoji 😀"] { XCTAssertEqual(AppearanceFontFamily.first(AppearanceFontFamily.quote(name)), name) }
    XCTAssertEqual(AppearanceFontFamily.names("\"Font, Comma\", \"Quote \\\" font\", serif"), ["Font, Comma", "Quote \" font", "serif"])
  }
  func testDirectorySelectionStylesAndMonospacedFilterMatch414ReferenceCases() throws {
    let fixture = try fixture(); let families = fixture.families.map(\.native); XCTAssertEqual(fixture.cases.count, 414)
    XCTAssertEqual(fixture.settingsSHA256, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    for item in fixture.cases {
      let role = try XCTUnwrap(AppearanceFontRole(rawValue: item.role))
      let result = AppearanceFontSelection(value: item.value, face: item.face, role: role, families: families)
      let context = (item.value ?? "nil") + "/" + item.role + "/" + (item.face?.postscriptName ?? "nil")
      XCTAssertEqual(result.resolved?.family.name, item.family, context); XCTAssertEqual(result.resolved?.face.value.postscriptName, item.postscript, context)
      XCTAssertEqual(result.title, item.title, context); XCTAssertEqual(result.selectedDefault, item.selectedDefault, context)
      XCTAssertEqual(result.styleEnabled, item.styleEnabled, context)
      let menu = AppearanceFontMenuState(.family); menu.open(role: role, value: item.value ?? "", face: item.face, families: families, keyboard: false)
      XCTAssertEqual(menu.options.dropFirst().map(\.title), item.familyOptions, context)
      XCTAssertFalse(menu.options.contains { $0.id == "custom" }, context); XCTAssertNil(menu.highlightedID)
    }
  }
  func testKeyboardEdgesRepeatedTypeaheadAndTimeoutDoNotUseAaPrefix() throws {
    let families = try fixture().families.map(\.native); let menu = AppearanceFontMenuState(.family)
    menu.open(role: .ui, value: "", face: nil, families: families, keyboard: true)
    XCTAssertEqual(menu.highlightedID, "default"); menu.move(-1); XCTAssertEqual(menu.highlightedID, "default")
    menu.type("G", now: 1); XCTAssertEqual(menu.highlightedID, "family:Georgia")
    menu.type("g", now: 1.1); XCTAssertEqual(menu.highlightedID, "family:Georgia")
    menu.type("Z", now: 2.2); XCTAssertEqual(menu.highlightedID, "family:Zed Mono")
    XCTAssertFalse(menu.space(now: 2.3)); XCTAssertTrue(menu.space(now: 3.4))
    menu.edge(last: true); menu.move(1); XCTAssertEqual(menu.highlightedID, "family:Mixed")
    menu.dismiss(); menu.move(1); menu.type("G", now: 5); XCTAssertNil(menu.highlightedID)
  }
  func testSameFamilyAndSameFaceAreNoopsAndFirstFaceClearsOnlyItsOverride() throws {
    let (store, root) = store(); let families = try fixture().families.map(\.native)
    let bold = try XCTUnwrap(families.first?.faces.last?.value)
    _ = store.setAppearanceFont(.ui, family: "\"Zed Mono\", Georgia", face: bold, dark: false)
    let before = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    let menu = AppearanceFontMenuState(.family); menu.open(role: .ui, value: "\"Zed Mono\", Georgia", face: bold, families: families, keyboard: true)
    XCTAssertTrue(menu.choose("family:Zed Mono", role: .ui, dark: false, value: "\"Zed Mono\", Georgia", face: bold, families: families, store: store))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), before); XCTAssertEqual(store.appearance.light.uiFace, bold)
    let styles = AppearanceFontMenuState(.style)
    styles.open(role: .ui, value: "\"Zed Mono\", Georgia", face: bold, families: families, keyboard: false)
    XCTAssertTrue(styles.choose("face:Zed-Bold", role: .ui, dark: false, value: "\"Zed Mono\", Georgia", face: bold, families: families, store: store))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), before)
    styles.open(role: .ui, value: "\"Zed Mono\", Georgia", face: bold, families: families, keyboard: false)
    XCTAssertTrue(styles.choose("face:Zed-Regular", role: .ui, dark: false, value: "\"Zed Mono\", Georgia", face: bold, families: families, store: store))
    XCTAssertNil(store.appearance.light.uiFace); XCTAssertEqual(store.appearance.light.uiFont, "\"Zed Mono\""); XCTAssertNil(store.appearance.dark.uiFont)
    XCTAssertEqual(store.appearance.fontFamily(.content, dark: false), "\"Zed Mono\""); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
  }
  func testUnavailableAndEmptyDirectoryOfferCustomInputWithTrimAndFaceClear() throws {
    let (store, _) = store()
    for families: [AppearanceFontCatalog.Family]? in [nil, []] {
      let menu = AppearanceFontMenuState(.family); menu.open(role: .content, value: "old", face: nil, families: families, keyboard: false)
      XCTAssertTrue(menu.custom); XCTAssertEqual(menu.options.map(\.id), ["default", "custom"]); XCTAssertEqual(menu.draft, "old")
      menu.draft = "  \"Missing, Font\", Georgia  "
      XCTAssertTrue(menu.choose("custom", role: .content, dark: true, value: "old", face: nil, families: families, store: store))
      XCTAssertEqual(store.appearance.dark.contentFont, "\"Missing, Font\", Georgia"); XCTAssertNil(store.appearance.dark.contentFace)
      menu.open(role: .content, value: "saved", face: nil, families: families, keyboard: true); menu.draft = "unsaved"; menu.dismiss()
      menu.open(role: .content, value: "saved", face: nil, families: families, keyboard: false); XCTAssertEqual(menu.draft, "saved")
      menu.draft = " \u{feff} "
      XCTAssertTrue(menu.choose("custom", role: .content, dark: true, value: "saved", face: nil, families: families, store: store))
      XCTAssertEqual(store.appearance.dark.contentFont, "")
      XCTAssertFalse(AppearanceFontSelection(value: "Georgia", face: nil, role: .content, families: families).styleEnabled)
    }
  }
  func testRendererUsesFallbackButOnlyFirstFamilyMayUseSelectedFace() throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance = appearance.settingFont(.ui, family: "Missing, Georgia", face: .init(family: "Georgia", fullName: "Georgia Bold", postscriptName: "Georgia-Bold"), dark: false)
    let font = appearance.nativeFont(size: 14); XCTAssertEqual(font.familyName, "Georgia"); XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    appearance = appearance.settingFont(.ui, family: "-apple-system, Georgia", dark: false)
    XCTAssertEqual(appearance.nativeFont(size: 14).fontName, NSFont.systemFont(ofSize: 14).fontName)
    appearance = appearance.settingFont(.ui, family: "\"Georgia\", serif", face: .init(family: "Georgia", fullName: "Georgia Bold", postscriptName: "Georgia-Bold"), dark: false)
    XCTAssertEqual(appearance.nativeFont(size: 14).fontName, "Georgia-Bold")
  }
  func testHiddenFamilyAndStyleMenusHaveReferenceWidthsAndKeepWindowAndFocus() async throws {
    let (store, root) = store(); let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    let (window, host, button, style) = try await host(store, role: .content, catalog: catalog); defer { window.close() }
    let owner = try XCTUnwrap(button.owner)
    let font = try XCTUnwrap(button.font)
    XCTAssertEqual(button.frame.width, (button.title as NSString).size(withAttributes: [.font: font]).width + 36, accuracy: 1)
    XCTAssertEqual(button.frame.height, 28); XCTAssertEqual(button.title, "与界面字体相同")
    XCTAssertEqual(button.font?.pointSize, 12); XCTAssertFalse(style.isEnabled)
    owner.toggle(button, keyboard: true); try await settle(host)
    XCTAssertTrue(owner.popup?.window === window); XCTAssertEqual(owner.popup?.frame.width, 240); XCTAssertEqual(owner.popup?.frame.height, 350)
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window)); XCTAssertEqual(owner.parent.menu.highlightedID, "default")
    owner.choose("family:Menlo", button: button); try await settle(host)
    XCTAssertEqual(store.appearance.light.contentFont, "\"Menlo\""); XCTAssertTrue(window.firstResponder === button); XCTAssertTrue(style.isEnabled)
    let styleOwner = try XCTUnwrap(style.owner); styleOwner.toggle(style, keyboard: true); try await settle(host)
    XCTAssertEqual(styleOwner.popup?.frame.width, 208)
    XCTAssertEqual((styleOwner.parent.menu as? AppearanceFontMenuState)?.options.map(\.title), AppearanceFontCatalog.family("Menlo")?.faces.map(\.style))
    styleOwner.choose("face:Menlo-Bold", button: style); try await settle(host)
    XCTAssertEqual(store.appearance.light.contentFace?.postscriptName, "Menlo-Bold"); XCTAssertTrue(window.firstResponder === style)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  func testHiddenCustomInputAutofocusDraftEnterEscapeMarkedTextAndFailure() async throws {
    let (store, root) = store(); let catalog = AppearanceFontCatalogSource(families: nil)
    let (window, host, button, style) = try await host(store, role: .content, catalog: catalog); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: false); try await settle(host)
    let popup = try XCTUnwrap(owner.popup); let field = try XCTUnwrap(find(popup, as: AppearanceCustomFontInput.Control.self).first)
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView); let inputOwner = try XCTUnwrap(field.owner)
    XCTAssertTrue(window.firstResponder === editor); XCTAssertFalse(editor.isContinuousSpellCheckingEnabled); XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
    editor.string = " \"Missing, Font\", Georgia "; field.stringValue = editor.string
    inputOwner.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertNil(store.appearance.light.contentFont); XCTAssertFalse(style.isEnabled)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window); try await settle(host)
    XCTAssertTrue(owner.popup === popup); XCTAssertFalse(owner.handle(try key(49, window, " "), button: button)); XCTAssertTrue(owner.parent.menu.presented)
    XCTAssertTrue(inputOwner.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))); XCTAssertTrue(owner.parent.menu.presented)
    editor.setMarkedText("组合", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: 0, length: 0))
    XCTAssertFalse(inputOwner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))); XCTAssertNil(store.appearance.light.contentFont)
    editor.unmarkText(); editor.string = " \"Missing, Font\", Georgia "
    XCTAssertTrue(inputOwner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))); try await settle(host)
    XCTAssertEqual(store.appearance.light.contentFont, "\"Missing, Font\", Georgia"); XCTAssertEqual(button.title, "Missing, Font"); XCTAssertTrue(window.firstResponder === button)
    owner.toggle(button, keyboard: false); try await settle(host)
    let nextField = try XCTUnwrap(find(try XCTUnwrap(owner.popup), as: AppearanceCustomFontInput.Control.self).first)
    XCTAssertEqual(nextField.stringValue, "\"Missing, Font\", Georgia")
    try FileManager.default.removeItem(at: root); try Data("blocked".utf8).write(to: root)
    let nextEditor = try XCTUnwrap(nextField.currentEditor() as? NSTextView); nextEditor.string = "new font"
    XCTAssertTrue(try XCTUnwrap(nextField.owner).control(nextField, textView: nextEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))); try await settle(host)
    XCTAssertEqual(store.appearance.light.contentFont, "\"Missing, Font\", Georgia"); XCTAssertEqual(button.title, "Missing, Font")
    XCTAssertNotNil(store.generalSettingsError); XCTAssertTrue(window.firstResponder === button)
    XCTAssertFalse(inputOwner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  func testHiddenMenuCancelDisabledRestoringAndUnmountCannotApplyStaleChoice() async throws {
    let (store, _) = store(); let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    let (window, host, button, _) = try await host(store, role: .ui, catalog: catalog); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(host)
    XCTAssertTrue(owner.handle(try key(125, window), button: button)); XCTAssertTrue(owner.handle(try key(48, window), button: button)); XCTAssertTrue(owner.parent.menu.presented)
    XCTAssertTrue(owner.handle(try key(53, window), button: button)); try await settle(host); XCTAssertTrue(window.firstResponder === button)
    XCTAssertNil(store.appearance.light.uiFont)
    store.restoringLibrary = true; try await settle(host); owner.toggle(button, keyboard: true); XCTAssertFalse(owner.parent.menu.presented)
    store.restoringLibrary = false; try await settle(host); button.isHidden = true; owner.toggle(button, keyboard: true); XCTAssertFalse(owner.parent.menu.presented)
    button.isHidden = false; owner.toggle(button, keyboard: true); try await settle(host); XCTAssertNotNil(owner.popup)
    host.rootView = AnyView(Text("Removed")); try await settle(host); XCTAssertNil(owner.popup)
    owner.choose("family:Menlo", button: button); XCTAssertNil(store.appearance.light.uiFont); XCTAssertFalse(window.isVisible)
  }
  func testSingleFaceStyleMenuFitsItsActual34PointHeight() async throws {
    let (store, _) = store()
    let face = AppearanceFontCatalog.Face(value: .init(family: "Only", fullName: "Only Regular", postscriptName: "Only-Regular"), style: "Regular", weight: 5, italic: false, monospaced: true)
    let catalog = AppearanceFontCatalogSource(families: [.init(name: "Only", faces: [face])])
    _ = store.setAppearanceFont(.ui, family: "Only", dark: false)
    let (window, host, _, style) = try await host(store, role: .ui, catalog: catalog); defer { window.close() }
    let owner = try XCTUnwrap(style.owner); XCTAssertTrue(style.isEnabled)
    owner.toggle(style, keyboard: true); try await settle(host)
    XCTAssertEqual(owner.popup?.frame.size, .init(width: 208, height: 34)); XCTAssertEqual(owner.parent.menu.highlightedID, "face:Only-Regular")
    XCTAssertTrue(owner.handle(try key(36, window), button: style)); try await settle(host)
    XCTAssertNil(store.appearance.light.uiFace); XCTAssertTrue(window.firstResponder === style); XCTAssertFalse(window.isVisible)
    XCTAssertNotNil(SettingsPopupMenuButton.placement(anchor: .init(x: 200, y: 100, width: 144, height: 28), viewport: .init(x: 0, y: 0, width: 500, height: 300), height: 34, width: 208))
  }
  func testOpeningFontStyleOrThemeClosesOtherMenusInOnlyItsOwnWindow() async throws {
    let (store, _) = store(); let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    _ = store.setAppearanceFont(.ui, family: "Menlo", dark: false)
    let themeMenu = CodeThemeMenuState()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AnyView(VStack {
      AppearanceFontPicker(store: store, role: .ui, dark: false, catalog: catalog)
      CodeThemeMenuButton(store: store, dark: false, menu: themeMenu).frame(width: 176, height: 28)
    }.frame(width: 600).frame(width: 850, height: 900)))
    window.contentView = host; try await settle(host)
    let controls = find(host, as: SettingsPopupMenuButton.Control.self)
    let family = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "浅色界面字体" })
    let style = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "浅色界面字体样式" })
    let theme = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "浅色代码主题" })
    let firstOwner = try XCTUnwrap(family.owner), styleOwner = try XCTUnwrap(style.owner), themeOwner = try XCTUnwrap(theme.owner)
    let (otherWindow, otherHost, other, _) = try await self.host(store, role: .ui, catalog: catalog); defer { otherWindow.close() }
    let otherOwner = try XCTUnwrap(other.owner); otherOwner.toggle(other, keyboard: true); try await settle(otherHost)
    firstOwner.toggle(family, keyboard: true); try await settle(host)
    XCTAssertNotNil(firstOwner.popup); XCTAssertNotNil(otherOwner.popup)
    styleOwner.toggle(style, keyboard: true); try await settle(host)
    XCTAssertNil(firstOwner.popup); XCTAssertNotNil(styleOwner.popup); XCTAssertNotNil(otherOwner.popup)
    themeOwner.toggle(theme, keyboard: true); try await settle(host)
    XCTAssertNil(styleOwner.popup); XCTAssertNotNil(themeOwner.popup); XCTAssertNotNil(otherOwner.popup)
    XCTAssertEqual(window.contentView?.subviews.filter { $0 is SettingsPopupMenuButton.HostingView }.count, 1)
    XCTAssertFalse(window.isVisible); XCTAssertFalse(otherWindow.isVisible)
  }
  private func host(_ store: WorkspaceStore, role: AppearanceFontRole, catalog: AppearanceFontCatalogSource) async throws -> (NSWindow, NSHostingView<AnyView>, SettingsPopupMenuButton.Control, SettingsPopupMenuButton.Control) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(AppearanceFontPicker(store: store, role: role, dark: false, catalog: catalog).frame(width: 600).frame(width: 850, height: 900)))
    window.contentView = host; try await settle(host)
    let buttons = find(host, as: SettingsPopupMenuButton.Control.self)
    return (window, host, try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "浅色" + role.title }), try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "浅色" + role.title + "样式" }))
  }
  private func find<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, as: type) } }
  private func key(_ code: UInt16, _ window: NSWindow, _ characters: String = "") throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
      windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
  }
}
