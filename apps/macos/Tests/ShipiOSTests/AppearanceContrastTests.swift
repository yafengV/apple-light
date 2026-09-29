import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceContrastTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Item: Decodable {
      let accent: String; let surface: String; let value: Double; let minimum: Double; let maximum: Double; let step: Double; let gradient: String
      let labelValue: Double; let inputClass: String; let labelClass: String; let containerClass: String; let changeValue: Double
    }
    let settingsSHA256: String; let cases: [Item]
  }
  private func reference() throws -> Fixture {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "contrast_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }
  func testActualReferenceDOMRangeSanitizes72CasesAndRetainsReadOnlyValue() async throws {
    let f = try reference(); XCTAssertEqual(f.cases.count, 72); XCTAssertEqual(f.settingsSHA256, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); let web = WKWebView(frame: .zero, configuration: configuration)
    let output = try await web.callAsyncJavaScript(#"""
      return values.map(v=>{const input=document.createElement('input');input.type='range';input.min='0';input.max='100';input.step='1';input.value=String(v);return Number(input.value)});
      """#, arguments: ["values": f.cases.map(\.value)], in: nil, contentWorld: .defaultClient)
    let values = try XCTUnwrap(output as? [Double])
    for (index, item) in f.cases.enumerated() {
      XCTAssertEqual(item.minimum, 0); XCTAssertEqual(item.maximum, 100); XCTAssertEqual(item.step, 1); XCTAssertEqual(item.changeValue, 73)
      XCTAssertEqual(item.labelValue, item.value); XCTAssertEqual(AppearanceContrastSlider.rangeValue(item.value), values[index])
      XCTAssertTrue(item.inputClass.contains("h-0.5")); XCTAssertTrue(item.inputClass.contains("slider-thumb]:h-5")); XCTAssertTrue(item.containerClass.contains("gap-2.5")); XCTAssertTrue(item.containerClass.contains("min-w-[12rem]")); XCTAssertTrue(item.labelClass.contains("w-9"))
    }
    XCTAssertNil(web.window)
  }
  func testHiddenKeyboardUsesOneTenAndEdgesPreservesOtherPaletteAndPersists() async throws {
    let f = try await fixture(); defer { f.window.close() }; let (store, slider) = (f.store, f.slider)
    let before = store.appearance; XCTAssertTrue(f.window.makeFirstResponder(slider)); XCTAssertEqual(slider.frame.size, .init(width: 192, height: 36))
    XCTAssertEqual(slider.accessibilityLabel(), "深色 对比度"); XCTAssertEqual(slider.track.width, 146); XCTAssertEqual(slider.thumb.size, .init(width: 20, height: 20))
    let font = try XCTUnwrap(slider.font)
    XCTAssertEqual(("1" as NSString).size(withAttributes: [.font: font]).width, ("8" as NSString).size(withAttributes: [.font: font]).width, accuracy: 0.01)
    for (code, expected): (UInt16, Double) in [(124,61),(126,62),(123,61),(125,60),(116,70),(121,60),(115,0),(119,100),(124,100)] {
      slider.keyDown(with: try key(code, f.window)); try await settle(f.host); XCTAssertEqual(store.appearance.dark.contrast, expected); XCTAssertTrue(f.window.firstResponder === slider)
    }
    var expected = before; expected.dark.contrast = 100; XCTAssertEqual(store.appearance, expected)
    XCTAssertEqual(try WorkspaceLibrary.load(from: f.root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(f.window.isVisible)
  }
  func testHiddenTrackClickThumbOffsetDraggingClampAndReadoutIsNotInteractive() async throws {
    let f = try await fixture(); defer { f.window.close() }; let slider = f.slider
    slider.mouseDown(with: try mouse(.leftMouseDown, .init(x: 180, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 60)
    slider.mouseDown(with: try mouse(.leftMouseDown, .init(x: 73, y: 18), slider, f.window)); try await settle(f.host); XCTAssertEqual(f.store.appearance.dark.contrast, 50)
    slider.mouseUp(with: try mouse(.leftMouseUp, .init(x: 73, y: 18), slider, f.window))
    slider.mouseDown(with: try mouse(.leftMouseDown, .init(x: slider.thumbX + 5, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 50)
    slider.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: 78 + 12.6, y: 18), slider, f.window)); try await settle(f.host); XCTAssertEqual(f.store.appearance.dark.contrast, 60)
    slider.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: 500, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 100)
    slider.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: -500, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 0)
    slider.mouseUp(with: try mouse(.leftMouseUp, .init(x: -500, y: 18), slider, f.window)); slider.mouseDragged(with: try mouse(.leftMouseDragged, .init(x: 73, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 0)
    XCTAssertFalse(f.window.isVisible)
  }
  func testHiddenAccessibilityFreshAvailabilityFailedSaveAndDetachedCallbacks() async throws {
    let f = try await fixture(); defer { f.window.close() }; let slider = f.slider; let before = f.store.appearance
    f.store.libraryLoaded = false; XCTAssertFalse(slider.accessibilityPerformIncrement()); XCTAssertEqual(f.store.appearance, before)
    f.store.libraryLoaded = true; f.store.restoringLibrary = true; XCTAssertFalse(slider.accessibilityPerformIncrement()); f.store.restoringLibrary = false
    XCTAssertTrue(f.window.makeFirstResponder(slider))
    try FileManager.default.createDirectory(at: f.root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    XCTAssertTrue(slider.accessibilityPerformIncrement()); try await settle(f.host); XCTAssertEqual(f.store.appearance, before); XCTAssertEqual(slider.value, 60)
    XCTAssertTrue(f.window.firstResponder === slider); XCTAssertTrue(find(f.host, as: AppearanceContrastSlider.Control.self).contains { $0 === slider }); XCTAssertNotNil(f.store.generalSettingsError)
    slider.isHidden = true; XCTAssertFalse(slider.accessibilityPerformDecrement()); slider.isHidden = false
    slider.removeFromSuperview(); XCTAssertFalse(slider.accessibilityPerformDecrement()); XCTAssertEqual(f.store.appearance, before); XCTAssertFalse(f.window.isVisible)
  }
  func testHiddenRTLKeyboardAndPointerUseLogicalValueDirection() async throws {
    let f = try await fixture(rtl: true); defer { f.window.close() }; let slider = f.slider
    XCTAssertEqual(slider.track.minX, 46); slider.keyDown(with: try key(123, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 61)
    slider.keyDown(with: try key(124, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 60)
    slider.mouseDown(with: try mouse(.leftMouseDown, .init(x: 46 + 10, y: 18), slider, f.window)); XCTAssertEqual(f.store.appearance.dark.contrast, 100)
    slider.mouseUp(with: try mouse(.leftMouseUp, .init(x: 46 + 10, y: 18), slider, f.window)); XCTAssertFalse(f.window.isVisible)
  }
  func testHiddenRestoringStateReleasesDisabledFocusAndRetainsControlOnRecovery() async throws {
    let f = try await fixture(); defer { f.window.close() }; XCTAssertTrue(f.window.makeFirstResponder(f.slider))
    f.store.restoringLibrary = true; try await settle(f.host)
    XCTAssertFalse(f.slider.isEnabled); XCTAssertFalse(f.slider.acceptsFirstResponder); XCTAssertFalse(f.window.firstResponder === f.slider)
    XCTAssertFalse(f.slider.accessibilityPerformIncrement()); XCTAssertEqual(f.store.appearance.dark.contrast, 60)
    f.store.restoringLibrary = false; try await settle(f.host)
    XCTAssertTrue(find(f.host, as: AppearanceContrastSlider.Control.self).first === f.slider)
    XCTAssertTrue(f.slider.isEnabled); XCTAssertTrue(f.window.makeFirstResponder(f.slider)); XCTAssertTrue(f.slider.accessibilityPerformIncrement())
    XCTAssertEqual(f.store.appearance.dark.contrast, 61); XCTAssertFalse(f.window.isVisible)
  }
  func testHiddenGradientPixelsMatchActualReferenceGradientInOfflineCanvas() async throws {
    let f = try await fixture(); defer { f.window.close() }; let slider = f.slider
    XCTAssertTrue(slider.owner?.choose(100, in: slider) == true); try await settle(f.host)
    let item = try XCTUnwrap(try reference().cases.first { $0.accent == "#339cff" && $0.surface == "#181818" })
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); let web = WKWebView(frame: .zero, configuration: configuration)
    let output = try await web.callAsyncJavaScript(#"""
      const colors=gradient.match(/color-mix\(in srgb, (#[0-9a-f]+) 35%, (#[0-9a-f]+)\)/);const canvas=document.createElement('canvas');canvas.width=146;canvas.height=2;
      const ctx=canvas.getContext('2d',{colorSpace:'srgb'}),g=ctx.createLinearGradient(0,0,146,0);
      g.addColorStop(0,colors[0]);g.addColorStop(.32,colors[1]);g.addColorStop(1,colors[1]);ctx.fillStyle=g;ctx.fillRect(0,0,146,2);
      return [20,60].map(x=>Array.from(ctx.getImageData(x,1,1,1).data));
      """#, arguments: ["gradient": item.gradient], in: nil, contentWorld: .defaultClient)
    let expected = try XCTUnwrap(output as? [[Int]])
    let rep = try XCTUnwrap(slider.bitmapImageRepForCachingDisplay(in: slider.bounds)); slider.cacheDisplay(in: slider.bounds, to: rep)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try XCTUnwrap(CGContext(data: nil, width: 192, height: 36, bitsPerComponent: 8, bytesPerRow: 768, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(try XCTUnwrap(rep.cgImage), in: .init(x: 0, y: 0, width: 192, height: 36)); let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    for (index,x) in [20,60].enumerated() {
      let alpha = Double(bytes[18*768+x*4+3]); XCTAssertGreaterThan(alpha, 200)
      // CoreGraphics returns premultiplied bytes; Canvas getImageData does not.
      for c in 0..<3 { XCTAssertEqual(Double(bytes[18*768+x*4+c]) * 255 / alpha, Double(expected[index][c]), accuracy: 3) }
    }
    XCTAssertNil(web.window); XCTAssertFalse(f.window.isVisible)
  }
  private struct Surface: View {
    @Bindable var store: WorkspaceStore; let rtl: Bool
    var body: some View { AppearanceContrastRow(store: store, dark: true).frame(width: 500).frame(width: 700, height: 500).environment(\.appAppearance, store.appearance).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight) }
  }
  private struct FixtureWindow { let root: URL; let store: WorkspaceStore; let window: NSWindow; let host: NSHostingView<Surface>; let slider: AppearanceContrastSlider.Control }
  private func fixture(rtl: Bool = false) async throws -> FixtureWindow {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("contrast-" + UUID().uuidString); let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: Surface(store: store, rtl: rtl)); window.contentView = host; try await settle(host)
    return .init(root: root, store: store, window: window, host: host, slider: try XCTUnwrap(find(host, as: AppearanceContrastSlider.Control.self).first))
  }
  private func find<T: NSView>(_ view: NSView, as type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, as: type) } }
  private func key(_ code: UInt16, _ window: NSWindow) throws -> NSEvent { try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)) }
  private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ view: NSView, _ window: NSWindow) throws -> NSEvent { try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)) }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
}
