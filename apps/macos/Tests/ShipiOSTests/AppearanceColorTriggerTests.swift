import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceColorTriggerTests: XCTestCase {
  func testNativeGeometryAndTextColorMatchThePublicTransparentInput() async throws {
    let appearance = palette()
    let (window, host) = host(AppearanceColorInput(value: "#FFFFFF", label: "颜色") { _ in true }
      .fixedSize().environment(\.appAppearance, appearance))
    defer { window.close() }; try await settle(host)
    let view = try XCTUnwrap(find(host, AppearanceColorInput.Control.self).first)
    XCTAssertEqual(view.frame.size, .init(width: 96, height: 28))
    XCTAssertEqual(view.swatch.frame, .init(x: 9, y: 7, width: 14, height: 14))
    XCTAssertEqual(view.field.frame, .init(x: 31, y: 6, width: 56, height: 16))
    XCTAssertEqual(view.field.textColor, NSColor(appearance.foregroundColor))
    XCTAssertEqual(view.field.stringValue, "#FFFFFF")
    XCTAssertEqual(view.field.accessibilityLabel(), "颜色")
  }
  func testOnlyTheSwatchPaintsTheSelectedColorAndTheBoxRemainsTransparent() async throws {
    let (window, host) = host(AppearanceColorInput(value: "#000000", label: "颜色") { _ in true }
      .fixedSize().environment(\.appAppearance, palette()))
    defer { window.close() }; try await settle(host)
    let view = try XCTUnwrap(find(host, AppearanceColorInput.Control.self).first), rect = view.convert(view.bounds, to: host)
    let point = CGPoint(x: rect.maxX - 12, y: rect.minY + 4)
    XCTAssertGreaterThan(try pixel(host, point).redComponent, 0.98)
    let swatch = view.swatch.convert(view.swatch.bounds, to: host)
    XCTAssertLessThan(try pixel(host, .init(x: swatch.midX, y: swatch.midY)).redComponent, 0.02)
    view.color = .init(hex: "#FFFFFF"); try await settle(host)
    XCTAssertGreaterThan(try pixel(host, point).redComponent, 0.98)
  }
  func testFocusWithinCoversTheWholeCapsuleAndRTLRetainsTheNativeEditor() async throws {
    let (window, host) = host(AppearanceColorInput(value: "#181818", label: "颜色") { _ in true }
      .fixedSize().environment(\.appAppearance, palette()).environment(\.layoutDirection, .rightToLeft))
    defer { window.close() }; try await settle(host)
    let view = try XCTUnwrap(find(host, AppearanceColorInput.Control.self).first)
    XCTAssertEqual(view.swatch.frame.minX, 73, accuracy: 0.1)
    XCTAssertEqual(view.field.frame.minX, 9, accuracy: 0.1)
    XCTAssertTrue(window.makeFirstResponder(view.field)); try await settle(host)
    let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 1, length: 2))
    let rect = view.convert(view.bounds, to: host), point = CGPoint(x: rect.minX - 1, y: rect.midY)
    let focused = try pixel(host, point)
    XCTAssertGreaterThan(focused.blueComponent - focused.redComponent, 0.3)
    host.layoutSubtreeIfNeeded(); try await settle(host)
    XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 2))
    XCTAssertTrue(window.makeFirstResponder(nil)); try await settle(host)
    XCTAssertGreaterThan(try pixel(host, point).redComponent, 0.98)
  }
  func testActualAccentCompositeUsesAnIntrinsicMenuAnd96PointColorEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.appearance.theme = "light"
    store.appearance.light.accentSource = "custom"
    let (window, host) = host(AppearanceAccentPicker(store: store, dark: false)
      .labeledContentStyle(AppearanceSettingsRowStyle()).frame(width: 628)
      .environment(\.appAppearance, store.appearance))
    defer { window.close() }; try await settle(host)
    let button = try XCTUnwrap(find(host, SettingsPopupMenuButton.Control.self).first)
    let color = try XCTUnwrap(find(host, AppearanceColorInput.Control.self).first)
    let font = try XCTUnwrap(button.font)
    XCTAssertEqual(button.frame.width, ceil((button.title as NSString).size(withAttributes: [.font: font]).width) + 36, accuracy: 1)
    XCTAssertEqual(color.frame.width, 96)
    let a = button.convert(button.bounds, to: host), b = color.convert(color.bounds, to: host)
    XCTAssertEqual(b.minX - a.maxX, 8, accuracy: 1)
    XCTAssertTrue(window.makeFirstResponder(color.field)); try await settle(host)
    XCTAssertNotNil(color.field.currentEditor())
  }
  func testActualColorAndAccentTreesResolveInTheFullDesktopStylesheet() async throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] else { throw XCTSkip("Set SHIPIOS_REFERENCE_CSS for the pinned stylesheet") }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_color_trigger_reference_673", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String]), data = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[2])
    let css = try XCTUnwrap(String(data: data, encoding: .utf8))
    let colors = try XCTUnwrap(fixture["colors"] as? [[String: Any]]), accents = try XCTUnwrap(fixture["accents"] as? [[String: Any]])
    let sections = try colors.map { "<section data-kind=\"color\">\(html(try XCTUnwrap($0["tree"])))</section>" }
      + accents.map { "<section data-kind=\"accent\" style=\"width:628px\">\(html(try XCTUnwrap($0["tree"])))</section>" }
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 850, height: 500)), loaded = expectation(description: "Actual color trees")
    let delegate = ColorTriggerNavigationDelegate { loaded.fulfill() }; web.navigationDelegate = delegate
    web.loadHTMLString("<!doctype html><html data-codex-window-type=\"electron\"><style>\(css)</style><style>:root{--color-text:#112233;--color-border:#445566;--color-ring:#0000ff}</style><body>\(sections.joined())</body></html>", baseURL: nil)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await web.evaluateJavaScript("""
      (()=>{
      // CSSStyleRule also exposes cssRules (often empty). Keep its declarations
      // while descending through grouping/nested rules.
      function rules(list){return [...list].flatMap(r=>[...(r.style?[r]:[]),...(r.cssRules?rules(r.cssRules):[])])}
      const all=rules(document.styleSheets[0].cssRules),ringRules=['ring-2:focus-within','ring-ring:focus-within'].map(end=>all.find(r=>r.selectorText?.endsWith(end)));
      if(ringRules.some(r=>!r))throw Error('Missing actual focus-within declarations');
      // An unattached WebKit document has no focus even when activeElement is
      // the input. Project the actual conditional declarations for rendering;
      // the native test above exercises real first-responder focus separately.
      const projected=document.createElement('style');projected.textContent='.reference-focus{'+ringRules.map(r=>r.style.cssText).join(';')+'}';document.head.appendChild(projected);
      return [...document.querySelectorAll('section[data-kind=color]')].map(s=>{const r=s.firstElementChild,i=r.querySelector('input'),b=r.querySelector('button'),style=getComputedStyle(r),ir=i.getBoundingClientRect(),br=b.getBoundingClientRect();
        i.focus();r.classList.add('reference-focus');const ring=getComputedStyle(r).boxShadow;
        return {width:r.getBoundingClientRect().width,height:r.getBoundingClientRect().height,background:style.backgroundColor,radius:parseFloat(style.borderRadius),border:parseFloat(style.borderWidth),color:getComputedStyle(i).color,
          fieldX:ir.x-r.getBoundingClientRect().x,fieldWidth:ir.width,fieldHeight:ir.height,swatchX:br.x-r.getBoundingClientRect().x,swatchWidth:br.width,ring}})
      })()
      """)
    let values = try XCTUnwrap(raw as? [[String: Any]]); XCTAssertEqual(values.count, 2)
    for item in values {
      XCTAssertEqual(item["width"] as? Double, 96); XCTAssertEqual(item["height"] as? Double, 28)
      XCTAssertEqual(item["background"] as? String, "rgba(0, 0, 0, 0)")
      XCTAssertEqual(item["radius"] as? Double, 9999); XCTAssertEqual(item["border"] as? Double, 1)
      XCTAssertEqual(item["color"] as? String, "rgb(17, 34, 51)")
      XCTAssertEqual(item["fieldX"] as? Double, 31); XCTAssertEqual(item["fieldWidth"] as? Double, 56)
      XCTAssertEqual(try XCTUnwrap(item["fieldHeight"] as? Double), 16, accuracy: 0.02)
      XCTAssertEqual(item["swatchX"] as? Double, 9); XCTAssertEqual(item["swatchWidth"] as? Double, 14)
      XCTAssertTrue((item["ring"] as? String)?.contains("rgb(0, 0, 255)") == true, String(describing: item["ring"]))
    }
    let accentRaw = try await web.evaluateJavaScript("[...document.querySelectorAll('section[data-kind=accent]')].map(s=>[s.querySelector('button').getBoundingClientRect().width,s.querySelector('input')?.parentElement.getBoundingClientRect().width??null])")
    let accentValues = try XCTUnwrap(accentRaw as? [[Any]])
    XCTAssertEqual(accentValues.count, 2); XCTAssertEqual(accentValues[0][1] as? Double, 96)
    XCTAssertTrue(accentValues[1][1] is NSNull)
    XCTAssertLessThan(try XCTUnwrap(accentValues[0][0] as? Double), 144)
  }
  private func palette() -> AppearancePreferences {
    var value = AppearancePreferences(); value.theme = "light"; value.light.background = "#FFFFFF"; value.light.foreground = "#000000"; value.light.accent = "#0000FF"; return value
  }
  private func html(_ value: Any) -> String {
    if let s = value as? String { return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
    if let a = value as? [Any] { return a.map(html).joined() }
    guard let n = value as? [String: Any], let p = n["props"] as? [String: Any] else { return "" }
    let type = n["type"] as? String ?? "span"
    if type == "fragment" { return html(p["children"] ?? "") }
    let tag = ["div", "span", "button", "input", "svg", "path"].contains(type) ? type : "span"
    let style = (p["style"] as? [String: Any])?["backgroundColor"] as? String
    return "<\(tag) class=\"\(p["className"] as? String ?? "")\"\(style.map { " style=\"background-color:\($0)\"" } ?? "")\(p["value"].map { " value=\"\($0)\"" } ?? "")>\(html(p["children"] ?? ""))</\(tag)>"
  }
  private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<some View>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white))
    window.contentView = host; return (window, host)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded() }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func pixel(_ host: NSView, _ point: CGPoint) throws -> NSColor {
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
    return try XCTUnwrap(rep.colorAt(x: Int(point.x * CGFloat(rep.pixelsWide) / host.bounds.width), y: Int(point.y * CGFloat(rep.pixelsHigh) / host.bounds.height)))
  }
}
@MainActor private final class ColorTriggerNavigationDelegate: NSObject, WKNavigationDelegate {
  let loaded: () -> Void
  init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
