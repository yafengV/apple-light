import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CodeThemePickerTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Item: Decodable { let variant: String; let current: String?; let query: String; let expected: String? }
    let cases: [Item]
  }
  private func store() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-picker-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  func testTypeaheadSearchBuffersMatch540CurrentReferenceResults() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "theme_menu_typeahead_reference", withExtension: "json", subdirectory: "Fixtures"))
    let cases = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).cases
    XCTAssertEqual(cases.count, 540)
    for item in cases {
      let menu = CodeThemeMenuState(); menu.open(dark: item.variant == "dark", keyboard: false)
      menu.highlightedID = item.current; menu.type(item.query, now: 2)
      XCTAssertEqual(menu.highlightedID, item.expected, item.variant + "/" + (item.current ?? "nil") + "/" + item.query)
    }
  }
  func testKeyboardEntryPointerEntryClampedEdgesAndTypeaheadExpiration() {
    let menu = CodeThemeMenuState(); menu.open(dark: true, keyboard: false)
    XCTAssertNil(menu.highlightedID); XCTAssertEqual(menu.options.count, 27)
    menu.move(-1); XCTAssertEqual(menu.highlightedID, "xcode")
    menu.move(1); XCTAssertEqual(menu.highlightedID, "xcode")
    menu.edge(last: false); XCTAssertEqual(menu.highlightedID, "absolutely")
    menu.move(-1); XCTAssertEqual(menu.highlightedID, "absolutely")
    menu.open(dark: false, keyboard: true); XCTAssertEqual(menu.highlightedID, "absolutely")
    menu.type("A", now: 2); menu.type("a", now: 2.1); menu.type("G", now: 2.2)
    XCTAssertEqual(menu.highlightedID, "github")
    XCTAssertFalse(menu.space(now: 2.3), "Space participates in an active typeahead buffer")
    XCTAssertTrue(menu.space(now: 3.4))
    menu.type("A", now: 4.5); menu.type("a", now: 4.6); menu.type("X", now: 4.7)
    XCTAssertEqual(menu.highlightedID, "xcode")
    menu.dismiss(); menu.move(1); menu.hover("github"); XCTAssertNil(menu.highlightedID)
    XCTAssertFalse(menu.space()); XCTAssertFalse(menu.presented)
  }
  func testCurrentPreviewUsesEachSidesActualPaletteAndLegacyFallback() throws {
    var appearance = AppearancePreferences(); appearance.accent = "#123456"; appearance.background = "#654321"
    XCTAssertEqual(appearance.themeSwatch(dark: false).accent, "#123456")
    XCTAssertEqual(appearance.themeSwatch(dark: true).background, "#654321")
    appearance.light.accent = "#ff0000"; appearance.light.background = "#00ff00"; appearance.light.foreground = "#0000ff"
    appearance.dark.accent = "#abcdef"; appearance.dark.background = "#101010"; appearance.dark.foreground = "#fafafa"
    XCTAssertEqual(appearance.themeSwatch(dark: false), .init(accent: "#ff0000", foreground: "#0000ff", background: "#00ff00"))
    XCTAssertEqual(appearance.themeSwatch(dark: true), .init(accent: "#abcdef", foreground: "#fafafa", background: "#101010"))
    let preset = try XCTUnwrap(CodeThemeCatalog.preset("github", dark: false)?.swatch(dark: false))
    XCTAssertNotEqual(preset, appearance.themeSwatch(dark: false))
    let share = appearance.themeShare(dark: false)
    let imported = try AppearancePreferences().importingThemeShare(share.encoded(), dark: false)
    XCTAssertEqual(imported.themeSwatch(dark: false), appearance.themeSwatch(dark: false))
  }
  func testRenderedAaSamplesHaveCorrectSizesSurfaceAndAccentPixels() throws {
    let swatch = SettingsMenuSwatch(accent: "#ff0000", foreground: "#000000", background: "#00ff00")
    for size: CGFloat in [24, 28] {
      let renderer = ImageRenderer(content: ThemeColorSwatch(swatch: swatch, size: size)); renderer.scale = 1
      let image = try XCTUnwrap(renderer.nsImage)
      XCTAssertEqual(image.size, .init(width: size, height: size))
      let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
      let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB))
      let solid = ImageRenderer(content: Rectangle().fill(Color(.sRGB, red: 0, green: 1, blue: 0)).frame(width: size, height: size))
      solid.scale = 1
      let expected = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(solid.cgImage)).colorAt(x: Int(size) / 2, y: 3)?.usingColorSpace(.sRGB))
      XCTAssertEqual(pixel.greenComponent, expected.greenComponent, accuracy: 0.01)
      XCTAssertEqual(pixel.redComponent, expected.redComponent, accuracy: 0.01)
      let reds = (0..<bitmap.pixelsWide).flatMap { x in (0..<bitmap.pixelsHigh).compactMap { y -> NSColor? in
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent > 0.7, color.greenComponent < 0.3 else { return nil }; return color
      } }
      XCTAssertGreaterThan(reds.count, 5, "Aa must use the accent color rather than the ink bars")
    }
    let native = try XCTUnwrap(swatch.image(appearance: .init()))
    XCTAssertEqual(native.size, .init(width: 24, height: 24))
  }
  func testPlacementAlignsTrailingEdgeFlipsAndConstrainToViewport() throws {
    let viewport = NSRect(x: 0, y: 0, width: 800, height: 700)
    let bottom = try XCTUnwrap(CodeThemeMenuButton.placement(anchor: .init(x: 400, y: 400, width: 176, height: 28), viewport: viewport, height: 328))
    XCTAssertEqual(bottom, .init(x: 336, y: 70, width: 240, height: 328))
    let top = try XCTUnwrap(CodeThemeMenuButton.placement(anchor: .init(x: 400, y: 20, width: 176, height: 28), viewport: viewport, height: 328))
    XCTAssertEqual(top, .init(x: 336, y: 50, width: 240, height: 328))
    let narrow = try XCTUnwrap(CodeThemeMenuButton.placement(anchor: .init(x: 6, y: 90, width: 100, height: 28), viewport: .init(x: 0, y: 0, width: 180, height: 210), height: 328))
    XCTAssertEqual(narrow.width, 168); XCTAssertTrue(NSRect(x: 6, y: 6, width: 168, height: 198).contains(narrow))
    XCTAssertNil(CodeThemeMenuButton.placement(anchor: .init(x: -300, y: 10, width: 176, height: 28), viewport: viewport, height: 328))
  }
  func testHiddenWindowMenuStaysInSameWindowAndEscapeDoesNotExitSettings() async throws {
    let (store, _) = store(); store.destination = .settings
    let menu = CodeThemeMenuState()
    let (window, host, button) = try await host(store, menu: menu); defer { window.close() }
    let owner = try XCTUnwrap(button.owner)
    owner.toggle(button, keyboard: true)
    XCTAssertNotNil(owner.popup); XCTAssertTrue(owner.popup?.window === window)
    XCTAssertEqual(owner.popup?.frame.width, 240); XCTAssertEqual(owner.popup?.frame.height, 328)
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    XCTAssertEqual(store.destination, .settings); XCTAssertEqual(menu.highlightedID, "absolutely")
    XCTAssertTrue(owner.handle(try key(125, window), button: button))
    XCTAssertEqual(menu.highlightedID, "catppuccin")
    XCTAssertTrue(owner.handle(try key(48, window), button: button)); XCTAssertTrue(menu.presented)
    XCTAssertTrue(owner.handle(try key(53, window), button: button))
    try await settle(host)
    XCTAssertNil(owner.popup); XCTAssertFalse(menu.presented); XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(store.destination, .settings); XCTAssertFalse(window.isVisible)
  }
  func testHiddenWindowKeyboardSelectionSavesOnlyRequestedSideAndReturnsFocus() async throws {
    let (store, root) = store(); let menu = CodeThemeMenuState()
    let (window, host, button) = try await host(store, menu: menu, dark: true); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true)
    XCTAssertTrue(owner.handle(try key(119, window), button: button)); XCTAssertEqual(menu.highlightedID, "xcode")
    XCTAssertTrue(owner.handle(try key(36, window), button: button)); try await settle(host)
    XCTAssertEqual(store.appearance.codeThemes, .init(dark: "xcode"))
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance?.codeThemes, .init(dark: "xcode"))
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertTrue(window.firstResponder === button)
    XCTAssertNil(owner.popup); XCTAssertEqual(button.title, "Xcode"); XCTAssertFalse(window.isVisible)
  }
  func testOutsideClickPassesThroughAndDoesNotStealNewFocus() async throws {
    let (store, _) = store(); let menu = CodeThemeMenuState()
    let (window, host, button) = try await host(store, menu: menu); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: false)
    let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 2, y: 2), modifierFlags: [],
      timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    XCTAssertFalse(owner.handle(outside, button: button)); XCTAssertFalse(menu.presented); XCTAssertNil(owner.popup)
    let field = NSTextField(frame: .init(x: 10, y: 10, width: 100, height: 24)); window.contentView?.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field)); try await settle(host)
    XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as AnyObject? === field)
    XCTAssertFalse(window.isVisible)
  }
  func testFocusOutsideAndResignKeyDismissWithoutReturningToTrigger() async throws {
    let (store, _) = store(); let menu = CodeThemeMenuState()
    let (window, host, button) = try await host(store, menu: menu); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: false)
    let field = NSTextField(frame: .init(x: 10, y: 10, width: 100, height: 24)); window.contentView?.addSubview(field)
    window.makeFirstResponder(field)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    try await settle(host); XCTAssertNil(owner.popup); XCTAssertFalse(menu.presented)
    XCTAssertFalse(window.firstResponder === button)
    owner.toggle(button, keyboard: false)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertFalse(menu.presented); XCTAssertNil(owner.popup); XCTAssertFalse(window.isVisible)
  }
  func testDisabledHiddenAndDetachedControlsCannotOpenOrApplyStaleChoice() async throws {
    let (store, _) = store(); let menu = CodeThemeMenuState()
    let (window, host, button) = try await host(store, menu: menu); defer { window.close() }
    let owner = try XCTUnwrap(button.owner); button.isEnabled = false
    owner.toggle(button, keyboard: false); XCTAssertFalse(menu.presented); XCTAssertFalse(button.accessibilityPerformPress())
    button.isEnabled = true; button.isHidden = true; owner.toggle(button, keyboard: false); XCTAssertFalse(menu.presented)
    button.isHidden = false; owner.toggle(button, keyboard: true); XCTAssertTrue(menu.presented)
    host.rootView = AnyView(Text("Removed")); try await settle(host)
    XCTAssertFalse(menu.presented); XCTAssertNil(owner.popup)
    owner.choose("github", button: button); XCTAssertEqual(store.appearance.codeThemes, .init()); XCTAssertFalse(window.isVisible)
  }
  private func host(_ store: WorkspaceStore, menu: CodeThemeMenuState, dark: Bool = false) async throws -> (NSWindow, NSHostingView<AnyView>, CodeThemeMenuButton.Control) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AnyView(CodeThemeMenuButton(store: store, dark: dark, menu: menu).frame(width: 176, height: 28).frame(width: 800, height: 720)))
    window.contentView = host; try await settle(host)
    func find(_ view: NSView) -> CodeThemeMenuButton.Control? { (view as? CodeThemeMenuButton.Control) ?? view.subviews.compactMap(find).first }
    return (window, host, try XCTUnwrap(find(host)))
  }
  private func key(_ code: UInt16, _ window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
  }
}
