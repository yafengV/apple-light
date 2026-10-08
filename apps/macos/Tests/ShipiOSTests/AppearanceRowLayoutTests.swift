import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceRowLayoutTests: XCTestCase {
  func testCompactRowsReserveThePublicControlAreaAtThreeWidthsAndBothDirections() async throws {
    for rtl in [false, true] {
      let label = NSView(), control = NSView()
      let (window, host) = host(AppearanceSettingsRow {
        AppearanceRowProbe(view: control).frame(width: 32, height: 28)
      } label: { AppearanceRowProbe(view: label).frame(maxWidth: .infinity).frame(height: 20) }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
      defer { window.close() }
      for width: CGFloat in [628, 328, 168] {
        window.setContentSize(.init(width: width, height: 300)); host.frame.size = .init(width: width, height: 300)
        try await settle(host)
        let l = label.convert(label.bounds, to: host), c = control.convert(control.bounds, to: host)
        let inner = width - 32, reserved = min(160, inner * 0.4)
        XCTAssertEqual(l.width, inner - reserved - 16, accuracy: 1)
        XCTAssertEqual(c.width, 32, accuracy: 1)
        XCTAssertEqual(rtl ? c.minX : c.maxX, rtl ? 16 : width - 16, accuracy: 1)
      }
    }
  }

  func testActualFontButtonsUseTheirTitleWidthAndKeepNativeIdentityDuringResize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.appearance.theme = "light"; store.appearance.light.contentFont = "\"Menlo\""
    let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    let (window, host) = host(AppearanceFontPicker(store: store, role: .content, dark: false, catalog: catalog)
      .environment(\.appAppearance, store.appearance)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    defer { window.close() }; try await settle(host)
    let buttons = find(host), first = try XCTUnwrap(buttons.first)
    XCTAssertEqual(buttons.count, 2); XCTAssertEqual(first.title, "Menlo")
    XCTAssertTrue(window.makeFirstResponder(first))
    for width: CGFloat in [628, 328, 500] {
      window.setContentSize(.init(width: width, height: 300)); host.frame.size = .init(width: width, height: 300)
      try await settle(host)
      XCTAssertTrue(find(host).first === first); XCTAssertTrue(window.firstResponder === first)
      for button in buttons {
        let font = try XCTUnwrap(button.font)
        let titleWidth = (button.title as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(button.frame.width, titleWidth + 36, accuracy: 1)
        XCTAssertEqual(button.frame.height, 28)
      }
      let a = first.convert(first.bounds, to: host), b = buttons[1].convert(buttons[1].bounds, to: host)
      XCTAssertEqual(b.minX - a.maxX, 8, accuracy: 1)
      XCTAssertEqual(b.maxX, width - 16, accuracy: 1)
    }
    XCTAssertFalse(window.isVisible)
  }

  func testActualTwoFontButtonsRetainTheirNaturalWidthsInANarrowRightToLeftRow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.appearance.light.contentFont = "\"Menlo\""
    let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    let (window, host) = host(AppearanceFontPicker(store: store, role: .content, dark: false, catalog: catalog)
      .environment(\.layoutDirection, .rightToLeft).frame(width: 168, height: 300, alignment: .topLeading))
    defer { window.close() }; try await settle(host)
    let buttons = find(host); XCTAssertEqual(buttons.count, 2)
    let a = try XCTUnwrap(buttons.first), b = buttons[1]
    let ar = a.convert(a.bounds, to: host), br = b.convert(b.bounds, to: host)
    XCTAssertEqual(ar.minX - br.maxX, 8, accuracy: 1)
    XCTAssertEqual(ar.maxX, 152, accuracy: 1)
    for button in buttons {
      XCTAssertEqual(button.frame.width,
        (button.title as NSString).size(withAttributes: [.font: try XCTUnwrap(button.font)]).width + 36, accuracy: 1)
    }
    XCTAssertTrue(window.makeFirstResponder(a))
    let owner = try XCTUnwrap(a.owner); owner.toggle(a, keyboard: true); try await settle(host)
    owner.dismiss(a, restore: true); try await settle(host)
    XCTAssertTrue(window.firstResponder === a)
  }

  func testDefaultAndInheritedChineseTitlesHaveEnoughSpaceForTheActualSwiftUIText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    store.appearance.theme = "light"
    for family in ["", "Menlo", "Times New Roman"] {
      store.appearance.uiFont = family
      for size in [11, 14, 16] {
        store.appearance.uiSize = Double(size)
        for role in [AppearanceFontRole.code, .content] {
          let (window, host) = host(AppearanceFontPicker(store: store, role: role, dark: false, controls: .family, catalog: catalog)
            .environment(\.appAppearance, store.appearance))
          defer { window.close() }; try await settle(host)
          let button = try XCTUnwrap(find(host).first)
          let text = NSHostingView(rootView: Text(button.title).appFont(size: 12).fixedSize()
            .environment(\.appAppearance, store.appearance))
          try await settle(text)
          XCTAssertGreaterThanOrEqual(button.frame.width - 36 + 1.0 / 64, text.fittingSize.width, button.title)
        }
      }
    }
  }

  func testLongCustomFamilyExceedsTheOldCapAndKeepsItsAccessibleTitleWhenNarrowed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.appearance.theme = "light"
    let title = "A very long installed family name"
    store.appearance.light.contentFont = "\"" + title + "\""
    let catalog = AppearanceFontCatalogSource(families: AppearanceFontCatalog.families)
    let (window, host) = host(AppearanceFontPicker(store: store, role: .content, dark: false, controls: .family, catalog: catalog)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    defer { window.close() }; try await settle(host)
    let button = try XCTUnwrap(find(host).first)
    XCTAssertEqual(button.title, title); XCTAssertGreaterThan(button.frame.width, 144)
    XCTAssertTrue(window.makeFirstResponder(button))
    window.setContentSize(.init(width: 168, height: 300)); host.frame.size = .init(width: 168, height: 300)
    try await settle(host)
    XCTAssertEqual(button.frame.width, 136, accuracy: 1)
    XCTAssertEqual(button.accessibilityValue() as? String, title)
    XCTAssertTrue(find(host).first === button); XCTAssertTrue(window.firstResponder === button)
  }

  func testActualPublicFontWrappersAndRowsResolveIntrinsicWidthsInFullDesktopCSS() async throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] else { throw XCTSkip("Set SHIPIOS_REFERENCE_CSS to verify full public CSS") }
    let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "appearance_row_layout_reference_672", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
    let data = try Data(contentsOf: URL(fileURLWithPath: path)), hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String])
    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[2])
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    let css = try XCTUnwrap(String(data: data, encoding: .utf8))
    let rows = try cases.flatMap { item in
      let name = try XCTUnwrap(item["name"] as? String), tree = try XCTUnwrap(item["tree"])
      return [628, 328, 168].map { "<section data-name=\"\(name)\" style=\"width:\($0)px\">\(html(tree))</section>" }
    }.joined()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 850, height: 1100)), loaded = expectation(description: "Actual font rows")
    let delegate = AppearanceRowNavigationDelegate { loaded.fulfill() }; web.navigationDelegate = delegate
    web.loadHTMLString("<!doctype html><html data-codex-window-type=\"electron\"><style>\(css)</style><body>\(rows)</body></html>", baseURL: nil)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await web.evaluateJavaScript("""
      [...document.querySelectorAll('section')].map(s=>{const r=s.firstElementChild,c=r.children[1],f=c.firstElementChild;
       const w=e=>e.getBoundingClientRect().width;
       const buttons=[...f.querySelectorAll('button')];
       const chrome=b=>{const t=b.querySelector('span.truncate'),canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font=getComputedStyle(b).font;return w(b)-ctx.measureText(t.textContent).width};
       return {name:s.dataset.name,width:w(s),label:w(r.children[0]),control:w(c),font:w(f),buttons:buttons.map(w),chrome:buttons.map(chrome),
        minimum:parseFloat(getComputedStyle(c).minWidth),gap:parseFloat(getComputedStyle(r).gap)}})
      """)
    let measurements = try XCTUnwrap(raw as? [[String: Any]])
    XCTAssertEqual(measurements.count, 15)
    for item in measurements {
      let width = try XCTUnwrap(item["width"] as? Double), minimum = try XCTUnwrap(item["minimum"] as? Double)
      XCTAssertEqual(minimum, min(160, (width - 32) * 0.4), accuracy: 0.02)
      XCTAssertEqual(item["gap"] as? Double, 16)
      let buttons = try XCTUnwrap(item["buttons"] as? [Double])
      let font = try XCTUnwrap(item["font"] as? Double), control = try XCTUnwrap(item["control"] as? Double)
      XCTAssertEqual(font, min(buttons.reduce(0, +) + Double(max(0, buttons.count - 1)) * 8, width - 32), accuracy: 0.02)
      XCTAssertEqual(control, max(minimum, font), accuracy: 0.02)
      XCTAssertEqual(try XCTUnwrap(item["label"] as? Double), max(0, width - 32 - control - 16), accuracy: 0.02)
      if width == 628 { for chrome in try XCTUnwrap(item["chrome"] as? [Double]) { XCTAssertEqual(chrome, 36, accuracy: 0.02) } }
      if item["name"] as? String == "family" { XCTAssertLessThan(try XCTUnwrap(buttons.first), 144) }
      if item["name"] as? String == "long", width == 628 { XCTAssertGreaterThan(try XCTUnwrap(buttons.first), 144) }
    }
  }
  private func html(_ value: Any) -> String {
    if let text = value as? String { return text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
    if let items = value as? [Any] { return items.map(html).joined() }
    guard let node = value as? [String: Any], let props = node["props"] as? [String: Any] else { return "" }
    let kind = node["type"] as? String ?? "span"
    if kind == "fragment" { return html(props["children"] ?? "") }
    let tag = ["div", "span", "button", "svg", "path"].contains(kind) ? kind : "span"
    return "<\(tag) class=\"\(props["className"] as? String ?? "")\">\(html(props["children"] ?? ""))</\(tag)>"
  }
  private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 628, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host; return (window, host)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded() }
  private func find(_ view: NSView) -> [SettingsPopupMenuButton.Control] { (view as? SettingsPopupMenuButton.Control).map { [$0] } ?? view.subviews.flatMap(find) }
}
private struct AppearanceRowProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
@MainActor private final class AppearanceRowNavigationDelegate: NSObject, WKNavigationDelegate {
  let loaded: () -> Void
  init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
