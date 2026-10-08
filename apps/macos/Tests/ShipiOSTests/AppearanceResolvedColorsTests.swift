import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceResolvedColorsTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Case: Decodable { let id: String; let variant: String; let theme: AppearanceThemeShare.Theme; let contrast: Double; let colors: [String: AppearanceRGBA] }
    struct Alpha: Decodable { let value: Double; let expected: Double }
    let sourceSHA256: String; let cssSHA256: String; let cases: [Case]; let alphaCases: [Alpha]
  }
  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "derived_theme_colors_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  func test303DistributedThemesProduceAll51ReferenceColorRoles() throws {
    let fixture = try fixture(); XCTAssertEqual(fixture.cases.count, 303)
    XCTAssertEqual(fixture.sourceSHA256, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(fixture.cssSHA256, "d5573a93b11a7826bf232e754d1b6353777d01c0bc067174f1701743537f9eea")
    for item in fixture.cases {
      let result = AppearanceResolvedColors(theme: item.theme, dark: item.variant == "dark")
      XCTAssertEqual(result.contrast, item.contrast, accuracy: 1e-12, item.id)
      XCTAssertEqual(Set(result.colors.keys), Set(item.colors.keys), item.id); XCTAssertEqual(result.colors.count, 51)
      for (role, expected) in item.colors {
        let actual = result[role]; let context = item.id + "/" + item.variant + "/" + role
        XCTAssertEqual(actual.red, expected.red, context); XCTAssertEqual(actual.green, expected.green, context); XCTAssertEqual(actual.blue, expected.blue, context)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: 1e-12, context)
      }
    }
  }
  func test1013AlphaSamplesMatchJavaScriptFixedPrecisionIncludingBinaryTies() throws {
    let cases = try fixture().alphaCases; XCTAssertEqual(cases.count, 1013)
    for item in cases { XCTAssertEqual(AppearanceRGBA.fixedAlpha(item.value), item.expected, accuracy: 1e-12, String(item.value)) }
    XCTAssertEqual(AppearanceRGBA.fixedAlpha(0.0625), 0.063)
    XCTAssertEqual(AppearanceRGBA.fixedAlpha(0.0005), 0.001)
    XCTAssertEqual(AppearanceRGBA.fixedAlpha(0.0025), 0.003)
  }
  func testContrastKeepsSurfaceAndRawInkWhileChangingControlsAndSupportsBlueException() {
    var appearance = AppearancePreferences(); appearance.theme = "dark"; appearance.dark.background = "#123456"; appearance.dark.foreground = "#abcdef"
    appearance.dark.contrast = 0; let low = appearance.resolvedColors
    appearance.dark.contrast = 100; let high = appearance.resolvedColors
    XCTAssertEqual(low["surface"], high["surface"]); XCTAssertEqual(low["surface"].hex, "#123456")
    XCTAssertEqual(low["ink"], high["ink"]); XCTAssertEqual(high["textForeground"].hex, "#abcdef")
    XCTAssertNotEqual(low["controlBackgroundOpaque"], high["controlBackgroundOpaque"])
    XCTAssertNotEqual(low["borderHeavy"].alpha, high["borderHeavy"].alpha)
    XCTAssertEqual(AppearancePreferences.hex(appearance.backgroundColor), "#123456")
    XCTAssertEqual(AppearancePreferences.hex(appearance.foregroundColor), "#ABCDEF")
    let blue = AppearanceRGBA(hex: "#339cff"); XCTAssertGreaterThan(blue.luminance, 0.179); XCTAssertEqual(blue.textOnAccent, .white)
    XCTAssertEqual(AppearanceRGBA(hex: "#ffffff").textOnAccent, .black)
    XCTAssertEqual(AppearanceRGBA(hex: "#000000").textOnAccent, .white)
  }
  func testDefaultDarkTextUsesGrayOnlyWhileWholeThemeRemainsDefault() {
    var appearance = AppearancePreferences(); appearance.theme = "dark"
    XCTAssertEqual(appearance.resolvedColors["ink"].hex, "#ffffff")
    XCTAssertEqual(appearance.resolvedColors["textForeground"].hex, "#dfdfdf")
    appearance.dark.accentSource = "custom"; XCTAssertEqual(appearance.resolvedColors["textForeground"].hex, "#dfdfdf")
    appearance.dark.uiFont = "Georgia"; XCTAssertEqual(appearance.resolvedColors["textForeground"].hex, "#ffffff")
    appearance.dark.uiFont = nil; appearance.dark.translucentSidebar = false
    XCTAssertEqual(appearance.resolvedColors["textForeground"].hex, "#ffffff")
    appearance.dark.translucentSidebar = true; appearance.dark.skill = "#123456"
    XCTAssertEqual(appearance.resolvedColors["textForeground"].hex, "#ffffff")
  }
  func testReferenceSurfaceAndControlColorsRenderOffscreenInSRGB() throws {
    let cases = try fixture().cases.filter { $0.id == "contrast/45" || $0.id == "contrast/60" || $0.id == "custom/#123456/100" }
    for item in cases {
      let colors = AppearanceResolvedColors(theme: item.theme, dark: item.variant == "dark")
      for role in ["surface", "surfaceUnder", "controlBackgroundOpaque", "applicationMenuBackground"] {
        let renderer = ImageRenderer(content: Rectangle().fill(colors[role].color).frame(width: 20, height: 20)); renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        // colorAt can return NSCalibratedRGBColorSpace even for an sRGB image.
        // Read the bytes after Core Graphics converts into the explicit sRGB buffer.
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (image.height / 2) * context.bytesPerRow + (image.width / 2) * 4
        let expected = try XCTUnwrap(item.colors[role]); let label = item.id + "/" + item.variant + "/" + role
        XCTAssertEqual(Double(bytes[offset]), Double(expected.red), accuracy: 1, label)
        XCTAssertEqual(Double(bytes[offset + 1]), Double(expected.green), accuracy: 1, label)
        XCTAssertEqual(Double(bytes[offset + 2]), Double(expected.blue), accuracy: 1, label)
        XCTAssertEqual(bytes[offset + 3], 255, label)
      }
    }
  }
  func testHiddenControlsUpdateColorsWithoutLosingNumericDraftFocusOrMenuIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("derived-colors-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    var initial = AppearancePreferences(); initial.theme = "dark"; initial.dark.background = "#123456"; store.appearance = initial
    store.library.drafts["fixture"] = "keep draft"
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: Surface(store: store).frame(width: 850, height: 900)); window.contentView = host; try await settle(host)
    let field = try XCTUnwrap(find(host, as: AppearanceFontSizeInput.Control.self).first)
    let button = try XCTUnwrap(find(host, as: SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "深色代码主题" })
    XCTAssertTrue(window.makeFirstResponder(field)); let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.string = "13.25"; field.stringValue = editor.string; editor.setSelectedRange(.init(location: 1, length: 2))
    try XCTUnwrap(field.owner).controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    var changed = store.appearance; changed.dark.background = "#503020"; changed.dark.accent = "#008cff"; changed.dark.contrast = 100
    XCTAssertTrue(store.commitAppearance(changed)); try await settle(host)
    XCTAssertTrue(find(host, as: AppearanceFontSizeInput.Control.self).contains { $0 === field }); XCTAssertTrue(window.firstResponder === editor)
    XCTAssertEqual(editor.string, "13.25"); XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 2)); XCTAssertEqual(store.appearance.uiSize, 14)
    assertColor(field.surface, changed.resolvedColors["controlBackground"])
    assertColor(field.border, changed.resolvedColors["borderHeavy"]); assertColor(field.focusBorder, changed.resolvedColors["borderFocus"])
    assertColor(button.surface, changed.resolvedColors["surface"]); assertColor(button.hoverSurface, changed.resolvedColors["buttonSecondaryBackgroundHover"])
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(host)
    let popup = try XCTUnwrap(owner.popup); XCTAssertTrue(button.expanded)
    changed = store.appearance; changed.dark.accent = "#aa33cc"; changed.dark.contrast = 45; XCTAssertTrue(store.commitAppearance(changed)); try await settle(host)
    XCTAssertTrue(owner.popup === popup); XCTAssertTrue(find(host, as: SettingsPopupMenuButton.Control.self).contains { $0 === button })
    assertColor(button.border, changed.resolvedColors["border"]); assertColor(button.chevronColor, changed.resolvedColors["textForegroundTertiary"])
    owner.dismiss(button, restore: true); try await settle(host); XCTAssertFalse(button.expanded); XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  private struct Surface: View {
    @Bindable var store: WorkspaceStore
    @State private var menu = CodeThemeMenuState()
    var body: some View {
      VStack {
        AppearanceFontSizeRow(store: store, kind: .ui)
        CodeThemeMenuButton(store: store, dark: true, menu: menu).frame(width: 176, height: 28)
      }.frame(width: 600).environment(\.appAppearance, store.appearance).background(store.appearance.backgroundColor)
    }
  }
  private func assertColor(_ actual: NSColor, _ expected: AppearanceRGBA, file: StaticString = #filePath, line: UInt = #line) {
    guard let color = actual.usingColorSpace(.sRGB) else { XCTFail("sRGB required", file: file, line: line); return }
    XCTAssertEqual(color.redComponent, Double(expected.red) / 255, accuracy: 1e-12, file: file, line: line)
    XCTAssertEqual(color.greenComponent, Double(expected.green) / 255, accuracy: 1e-12, file: file, line: line)
    XCTAssertEqual(color.blueComponent, Double(expected.blue) / 255, accuracy: 1e-12, file: file, line: line)
    XCTAssertEqual(color.alphaComponent, expected.alpha, accuracy: 1e-12, file: file, line: line)
  }
  private func find<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, as: type) } }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50))
  }
}
