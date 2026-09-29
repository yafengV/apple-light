import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceColorInputTests: XCTestCase {
  private struct Fixture: Decodable {
    struct HSV: Decodable { let h: Double; let s: Double; let v: Double; var value: AppearanceHSV { .init(hue: h, saturation: s, brightness: v) } }
    struct HSL: Decodable { let h: Double; let s: Double; let l: Double; var values: [Double] { [h, s, l] } }
    struct Edit: Decodable { let input: String; let sanitized: String; let parsed: String? }
    struct Color: Decodable { let hex: String; let ink: String; let hsv: HSV; let roundTrip: String; let hsl: HSL }
    struct Motion: Decodable { let hex: String; let axis: String; let left: Double; let top: Double; let hsv: HSV; let output: String }
    struct RGBA: Decodable { let hsv: HSV; let output: String; let hsl: HSL }
    let settingsSHA256: String; let pickerSHA256: String; let edits: [Edit]; let colors: [Color]; let motions: [Motion]; let rgba: [RGBA]
    let pickerCSS: String; let layoutCSS: String; let spacing: String
  }
  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "color_input_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  func testReferenceEditingReadabilityConversionsAndKeyboardSamples() throws {
    let f = try fixture(); XCTAssertEqual(f.settingsSHA256, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    XCTAssertEqual(f.pickerSHA256, "e381729764540940326372f7785bd5f68bc7dd2e49fad0eed4d8a99bbb3de706")
    XCTAssertEqual(f.edits.count, 122); XCTAssertEqual(f.colors.count, 176); XCTAssertEqual(f.motions.count, 288); XCTAssertEqual(f.rgba.count, 250)
    for item in f.edits { XCTAssertEqual(AppearanceColorEditing.sanitized(item.input), item.sanitized, item.input); XCTAssertEqual(AppearanceColorEditing.parsed(item.sanitized), item.parsed, item.input) }
    for item in f.colors {
      let hsv = AppearanceHSV(hex: item.hex)
      XCTAssertEqual(AppearanceColorEditing.readableInk(item.hex).hex, item.ink, item.hex)
      XCTAssertEqual(hsv, item.hsv.value, item.hex); XCTAssertEqual(hsv.color.hex, item.roundTrip, item.hex); XCTAssertEqual(hsv.hsl, item.hsl.values, item.hex)
    }
    for item in f.motions {
      let result = AppearanceHSV(hex: item.hex).stepping(item.axis == "hue" ? .hue : .color, left: item.left, top: item.top)
      XCTAssertEqual(result, item.hsv.value, item.hex + "/" + item.axis); XCTAssertEqual(result.color.hex, item.output)
    }
    for item in f.rgba { XCTAssertEqual(item.hsv.value.color.hex, item.output); XCTAssertEqual(item.hsv.value.hsl, item.hsl.values) }
    XCTAssertEqual(AppearanceColorEditing.readableInk("invalid").hex, "#101010")
    XCTAssertNil(AppearanceColorEditing.parsed("#abcdef"))
    XCTAssertEqual(AppearanceHSV(hex: "#123456").moving(.color, left: -1, top: 2), .init(hue: 210, saturation: 0, brightness: 0))
    XCTAssertEqual(AppearanceHSV(hex: "#123456").moving(.hue, left: 2, top: 0).hue, 360)
  }
  func testDistributedPickerCSSCascadeUses200PixelsDespiteLayeredSizeUtilities() async throws {
    let result = try await referenceRendering()
    XCTAssertEqual(result.sizes, [[200, 200], [200, 176], [200, 164], [200, 24]])
    XCTAssertEqual(result.huePixel[3], 255)
  }
  private struct ReferenceRendering: Decodable { let sizes: [[Double]]; let huePixel: [Int] }
  private func referenceRendering() async throws -> ReferenceRendering {
    let f = try fixture(); let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration); XCTAssertNil(web.window)
    let output = try await web.callAsyncJavaScript(#"""
      document.documentElement.style.setProperty('--spacing',spacing);
      const layout=document.createElement('style');layout.textContent=layoutCSS;document.head.appendChild(layout);
      const base=document.createElement('style');base.textContent='*{box-sizing:border-box}';document.head.appendChild(base);
      const injected=document.createElement('style');injected.textContent=pickerCSS;document.head.appendChild(injected);
      const picker=document.createElement('div');picker.className='react-colorful h-34 w-34';
      picker.innerHTML='<div class="react-colorful__saturation"><div class="react-colorful__interactive"></div></div><div class="react-colorful__hue react-colorful__last-control"></div>';
      document.body.appendChild(picker);
      const size=e=>{const r=e.getBoundingClientRect();return [r.width,r.height]};
      const canvas=document.createElement('canvas');canvas.width=200;canvas.height=24;
      const ctx=canvas.getContext('2d',{colorSpace:'srgb',alpha:false}),gradient=ctx.createLinearGradient(0,0,200,0);
      const stops=pickerCSS.match(/\.react-colorful__hue\{background:linear-gradient\(90deg,([^)]*)\)/)[1].split(',');
      stops.forEach((stop,index)=>{const match=stop.trim().match(/^(.*?)\s+([\d.]+)%?$/);gradient.addColorStop(match?Number(match[2])/100:index===0?0:1,match?match[1]:stop.trim());});
      ctx.fillStyle=gradient;ctx.fillRect(0,0,200,24);
      return JSON.stringify({sizes:[size(picker),size(picker.children[0]),size(picker.children[0].children[0]),size(picker.children[1])],huePixel:Array.from(ctx.getImageData(100,12,1,1).data)});
      """#, arguments: ["pickerCSS": f.pickerCSS, "layoutCSS": f.layoutCSS, "spacing": f.spacing], in: nil, contentWorld: .defaultClient)
    let result = try JSONDecoder().decode(ReferenceRendering.self, from: Data(try XCTUnwrap(output as? String).utf8))
    XCTAssertNil(web.window)
    return result
  }
  func testHiddenTextEditsSaveImmediatelyPartialDraftSurvivesExternalChangeAndBlurRestores() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }
    let (store, host, window) = (fixture.store, fixture.host, fixture.window); try await settle(host)
    let view = try XCTUnwrap(find(host, as: AppearanceColorInput.Control.self).first { $0.field.accessibilityLabel() == "深色背景色" })
    XCTAssertEqual(view.frame.size, .init(width: 136, height: 28)); XCTAssertEqual(view.field.stringValue, "#181818")
    XCTAssertTrue(window.makeFirstResponder(view.field)); let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView)
    enter("#12", in: view); XCTAssertEqual(view.owner?.draft, "#12"); XCTAssertNil(store.appearance.dark.background)
    var external = store.appearance; external.dark.background = "#654321"; XCTAssertTrue(store.commitAppearance(external)); try await settle(host)
    XCTAssertEqual(editor.string, "#12"); XCTAssertEqual(view.color.hex, "#654321"); XCTAssertTrue(window.firstResponder === editor)
    enter("#a!b c#d#ef89", in: view); try await settle(host)
    XCTAssertEqual(store.appearance.dark.background, "#ABCDEF"); XCTAssertEqual(editor.string, "#ABCDEF"); XCTAssertNil(view.owner?.draft)
    XCTAssertNil(store.appearance.light.background); XCTAssertNil(store.appearance.dark.foreground)
    enter("#f", in: view); XCTAssertTrue(window.makeFirstResponder(view.swatch)); try await settle(host)
    XCTAssertEqual(view.field.stringValue, "#ABCDEF"); XCTAssertNil(view.owner?.draft)
    XCTAssertEqual(try WorkspaceLibrary.load(from: fixture.root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  func testHiddenPopoverNoAutofocusKeyboardDraggingMenuMutualExclusionAndStaleCallbacks() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }; try await settle(fixture.host)
    let view = try XCTUnwrap(find(fixture.host, as: AppearanceColorInput.Control.self).first)
    let owner = try XCTUnwrap(view.owner); XCTAssertTrue(fixture.window.makeFirstResponder(view.swatch)); owner.toggle(view); try await settle(fixture.host)
    let popup = try XCTUnwrap(owner.popup); XCTAssertTrue(popup.window === fixture.window); XCTAssertTrue(fixture.window.firstResponder === view.swatch)
    XCTAssertTrue(SettingsPopupMenuButton.hasOpenMenu(in: fixture.window)); XCTAssertFalse(fixture.store.closeSettingsFromKeyboard(in: fixture.window))
    let canvas = try XCTUnwrap(find(popup, as: AppearanceColorPickerCanvas.Canvas.self).first)
    XCTAssertEqual(canvas.frame.size, .init(width: 200, height: 200)); XCTAssertEqual(canvas.color.frame.height, 164)
    XCTAssertEqual(canvas.color.accessibilityLabel(), "Color"); XCTAssertEqual(canvas.hue.accessibilityLabel(), "Hue")
    XCTAssertTrue(fixture.window.makeFirstResponder(canvas.color))
    canvas.change(canvas.color, left: 0.5, top: 0.2, keyboard: false); try await settle(fixture.host)
    XCTAssertEqual(fixture.store.appearance.dark.background, "#CC6666"); XCTAssertTrue(owner.popup === popup)
    XCTAssertTrue(find(popup, as: AppearanceColorPickerCanvas.Canvas.self).first === canvas); XCTAssertTrue(fixture.window.firstResponder === canvas.color)
    XCTAssertTrue(fixture.window.makeFirstResponder(canvas.hue)); canvas.hue.keyDown(with: key(124, window: fixture.window)); try await settle(fixture.host)
    XCTAssertEqual(owner.hsv.hue, 18); XCTAssertEqual(fixture.store.appearance.dark.background, "#CC8566")
    XCTAssertFalse(owner.handle(key(48, window: fixture.window), in: view), "Tab remains native; it is not a menu typeahead loop")
    let stale = try XCTUnwrap(canvas.onChange)
    let theme = try XCTUnwrap(find(fixture.host, as: SettingsPopupMenuButton.Control.self).first)
    try XCTUnwrap(theme.owner).toggle(theme, keyboard: true); try await settle(fixture.host)
    XCTAssertNil(owner.popup); let saved = fixture.store.appearance
    stale(.init(hue: 180, saturation: 100, brightness: 100)); XCTAssertEqual(fixture.store.appearance, saved)
    try XCTUnwrap(theme.owner).dismiss(theme, restore: false); owner.toggle(view); try await settle(fixture.host)
    XCTAssertTrue(owner.handle(key(53, window: fixture.window), in: view)); try await settle(fixture.host)
    XCTAssertNil(owner.popup); XCTAssertTrue(fixture.window.firstResponder === view.swatch); XCTAssertFalse(fixture.window.isVisible)
  }
  func testHiddenFailedSaveRetainsEditorAndActualColorAndRejectsDisabledDetachedActions() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }; try await settle(fixture.host)
    let view = try XCTUnwrap(find(fixture.host, as: AppearanceColorInput.Control.self).first); let owner = try XCTUnwrap(view.owner)
    XCTAssertTrue(fixture.window.makeFirstResponder(view.field)); let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView)
    let saved = fixture.store.appearance
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    enter("#abcdef", in: view); try await settle(fixture.host)
    XCTAssertEqual(fixture.store.appearance, saved); XCTAssertNotNil(fixture.store.generalSettingsError); XCTAssertEqual(editor.string, "#181818")
    XCTAssertTrue(fixture.window.firstResponder === editor); XCTAssertTrue(find(fixture.host, as: AppearanceColorInput.Control.self).contains { $0 === view })
    fixture.store.libraryLoaded = false; try await settle(fixture.host); owner.toggle(view); XCTAssertNil(owner.popup)
    fixture.store.libraryLoaded = true; try await settle(fixture.host); view.isHidden = true; owner.toggle(view); XCTAssertNil(owner.popup)
    view.isHidden = false; view.removeFromSuperview(); owner.toggle(view); XCTAssertNil(owner.popup)
    enter("#ff0000", in: view); XCTAssertEqual(fixture.store.appearance, saved)
  }
  func testHiddenOutsideClickPassesThroughWindowResignClosesAndPlacementClamps() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }; try await settle(fixture.host)
    let view = try XCTUnwrap(find(fixture.host, as: AppearanceColorInput.Control.self).first); let owner = try XCTUnwrap(view.owner)
    owner.toggle(view); try await settle(fixture.host)
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 820, y: 880), modifierFlags: [], timestamp: 1, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    XCTAssertFalse(owner.handle(event, in: view)); XCTAssertNil(owner.popup)
    owner.toggle(view); try await settle(fixture.host); NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
    XCTAssertNil(owner.popup)
    let viewport = CGRect(x: 0, y: 0, width: 800, height: 900)
    let below = try XCTUnwrap(AppearanceColorInput.placement(anchor: .init(x: 700, y: 600, width: 14, height: 14), viewport: viewport))
    XCTAssertEqual(below.maxX, 714); XCTAssertEqual(below.maxY, 592)
    let above = try XCTUnwrap(AppearanceColorInput.placement(anchor: .init(x: 20, y: 20, width: 14, height: 14), viewport: viewport))
    XCTAssertEqual(above.minX, 6); XCTAssertEqual(above.minY, 42)
    XCTAssertNil(AppearanceColorInput.placement(anchor: .init(x: 0, y: 950, width: 14, height: 14), viewport: viewport))
  }
  func testFullHiddenAppearancePageHasSixColorTextControlsUsingRawInkNotDerivedText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-color-page-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }; let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    var appearance = AppearancePreferences(); appearance.theme = "dark"; store.appearance = appearance
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 1400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store).environment(\.appAppearance, appearance).frame(width: 1000, height: 1400))
    window.contentView = host; try await settle(host)
    let controls = find(host, as: AppearanceColorInput.Control.self); XCTAssertEqual(controls.count, 6)
    XCTAssertEqual(controls.filter { ["浅色背景色", "深色背景色", "浅色前景色", "深色前景色"].contains($0.field.accessibilityLabel() ?? "") }.count, 4)
    XCTAssertEqual(controls.filter { ["浅色模式下的自定义强调色", "深色自定义强调色"].contains($0.field.accessibilityLabel() ?? "") }.count, 2)
    let ink = try XCTUnwrap(controls.first { $0.field.accessibilityLabel() == "深色前景色" }); XCTAssertEqual(ink.field.stringValue, "#FFFFFF")
    XCTAssertEqual(store.appearance.resolvedColors["textForeground"].hex, "#dfdfdf"); XCTAssertFalse(window.isVisible)
  }
  func testMarkedTextIsNotSanitizedOrSavedAndEnterDoesNotCommitPartialHex() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }; try await settle(fixture.host)
    let view = try XCTUnwrap(find(fixture.host, as: AppearanceColorInput.Control.self).first)
    XCTAssertTrue(fixture.window.makeFirstResponder(view.field)); let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView)
    editor.setMarkedText("输入", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: editor.string.utf16.count))
    XCTAssertTrue(editor.hasMarkedText()); view.owner?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: view.field))
    XCTAssertEqual(editor.string, "输入"); XCTAssertNil(fixture.store.appearance.dark.background)
    XCTAssertFalse(try XCTUnwrap(view.owner).control(view.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    editor.unmarkText(); enter("#ab", in: view)
    XCTAssertTrue(try XCTUnwrap(view.owner).control(view.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(editor.string, "#AB"); XCTAssertNil(fixture.store.appearance.dark.background)
  }
  func testHiddenPickerDrawsSaturationBlackSeparatorAndHueIntoExplicitSRGB() async throws {
    let fixture = try makeSurface(); defer { fixture.close() }; try await settle(fixture.host)
    let view = try XCTUnwrap(find(fixture.host, as: AppearanceColorInput.Control.self).first); try XCTUnwrap(view.owner).toggle(view); try await settle(fixture.host)
    let popup = try XCTUnwrap(view.owner?.popup); let canvas = try XCTUnwrap(find(popup, as: AppearanceColorPickerCanvas.Canvas.self).first)
    let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)); canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    let image = try XCTUnwrap(bitmap.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: 200, height: 200)); let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let browser = try await referenceRendering()
    // Compare the native hue pixel with the actual offline browser paint, rather
    // than assuming a sampled pixel center lands exactly on the cyan color stop.
    for (x, y, expected) in [(100, 82, [128, 64, 64]), (100, 170, [0, 0, 0]), (100, 188, Array(browser.huePixel.prefix(3)))] {
      for channel in 0..<3 { XCTAssertEqual(Double(bytes[y * 800 + x * 4 + channel]), Double(expected[channel]), accuracy: 3, "\(x),\(y),\(channel)") }
      XCTAssertEqual(bytes[y * 800 + x * 4 + 3], 255)
    }
    XCTAssertFalse(fixture.window.isVisible)
  }
  private struct Surface: View {
    @Bindable var store: WorkspaceStore
    @State private var menu = CodeThemeMenuState()
    var body: some View {
      VStack(spacing: 24) {
        AppearanceColorInput(value: store.appearance.themeShare(dark: true).theme.surface, label: "深色背景色", available: { store.libraryLoaded }) {
          store.setAppearanceColor($0, key: \.background, dark: true)
        }.frame(width: 136, height: 28).disabled(!store.libraryLoaded)
        CodeThemeMenuButton(store: store, dark: true, menu: menu).frame(width: 176, height: 28)
      }.frame(width: 850, height: 900).environment(\.appAppearance, store.appearance)
    }
  }
  @MainActor private struct HiddenFixture {
    let root: URL; let store: WorkspaceStore; let window: NSWindow; let host: NSView
    func close() { window.close(); try? FileManager.default.removeItem(at: root) }
  }
  private func makeSurface() throws -> HiddenFixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-color-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings; store.library.drafts["fixture"] = "keep draft"
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 900), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Surface(store: store)); window.contentView = host
    return .init(root: root, store: store, window: window, host: host)
  }
  private func enter(_ text: String, in view: AppearanceColorInput.Control) {
    view.field.stringValue = text; view.field.currentEditor()?.string = text
    view.owner?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: view.field))
  }
  private func key(_ code: UInt16, window: NSWindow) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)! }
  private func find<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, as: type) } }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
}
