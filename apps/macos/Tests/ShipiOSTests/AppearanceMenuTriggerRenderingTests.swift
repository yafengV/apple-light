import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceMenuTriggerRenderingTests: XCTestCase {
  func testActualReferenceTreesResolveAllFourAppearanceVariantsInFullDesktopCSS() async throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] else { throw XCTSkip("Set SHIPIOS_REFERENCE_CSS to verify the pinned full public stylesheet") }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_menu_trigger_reference_671", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String]), data = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[2])
    let css = try XCTUnwrap(String(data: data, encoding: .utf8)), cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    let swatch = try XCTUnwrap((fixture["swatches"] as? [[String: Any]])?.first?["tree"])
    for item in cases {
      let kind = try XCTUnwrap(item["kind"] as? String), disabled = item["disabled"] as? Bool == true
      let web = WKWebView(frame: .init(x: 0, y: 0, width: 850, height: 300))
      let loaded = expectation(description: kind), delegate = AppearanceTriggerNavigationDelegate { loaded.fulfill() }; web.navigationDelegate = delegate
      web.loadHTMLString("""
        <!doctype html><html data-codex-window-type="electron"><head><style>\(css)</style>
        <style>:root{--app-color-background-surface:#112233;--app-color-background-elevated-secondary:#445566;--app-color-background-button-secondary-hover:#778899}</style>
        </head><body>\(html(try XCTUnwrap(item["tree"]), swatch: swatch))</body></html>
        """, baseURL: nil)
      await fulfillment(of: [loaded], timeout: 10)
      let raw = try await web.evaluateJavaScript("""
        (()=>{const b=document.querySelector('button'),s=getComputedStyle(b),sw=b.querySelector('[aria-hidden]');
        const v={width:b.getBoundingClientRect().width,height:b.getBoundingClientRect().height,font:parseFloat(s.fontSize),
          left:parseFloat(s.paddingLeft),right:parseFloat(s.paddingRight),radius:parseFloat(s.borderRadius),
          opacity:parseFloat(s.opacity),background:s.backgroundColor,swatch:sw?.getBoundingClientRect().width};
        b.setAttribute('data-state','open');v.open=getComputedStyle(b).backgroundColor;return v})()
        """)
      let values = try XCTUnwrap(raw as? [String: Any])
      let code = kind == "codeTheme"
      XCTAssertEqual(values["width"] as? Double, code ? 176 : 850, kind)
      XCTAssertEqual(values["height"] as? Double, 28, kind)
      XCTAssertEqual(values["font"] as? Double, code ? 13 : 12, kind)
      XCTAssertEqual(values["left"] as? Double, code ? 3 : 8, kind)
      XCTAssertEqual(values["right"] as? Double, code ? 12 : 8, kind)
      XCTAssertEqual(values["radius"] as? Double, 9999, kind)
      XCTAssertEqual(values["opacity"] as? Double, disabled ? 0.4 : 1, kind)
      XCTAssertEqual(values["background"] as? String, kind.hasPrefix("font") ? "rgb(68, 85, 102)" : "rgb(17, 34, 51)", kind)
      XCTAssertEqual(values["open"] as? String, "rgb(119, 136, 153)", kind)
      if code { XCTAssertEqual(values["swatch"] as? Double, 20) }
    }
  }
  func testActualNativeCodeThemeSurfaceUsesSurfaceColorAndDisabledOpacity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.appearance.theme = "light"; store.appearance.light.background = "#000000"; store.appearance.light.foreground = "#ffffff"
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: CodeThemePicker(store: store, dark: false).padding(20).background(Color.white).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    let button = try XCTUnwrap(find(host).first), rect = button.convert(button.bounds, to: host)
    let normal = try pixel(host, point: .init(x: rect.minX + 40, y: rect.minY + 4))
    XCTAssertLessThan(normal.redComponent, 0.02); XCTAssertLessThan(normal.greenComponent, 0.02)
    let corner = try pixel(host, point: .init(x: rect.minX + 2, y: rect.minY + 2))
    XCTAssertGreaterThan(corner.greenComponent, 0.98, "Capsule corner leaves the host background visible")
    button.isEnabled = false; try await settle(host)
    let disabled = try pixel(host, point: .init(x: rect.minX + 40, y: rect.minY + 4))
    XCTAssertEqual(disabled.greenComponent, 0.6, accuracy: 3.0 / 255)
    XCTAssertFalse(window.isVisible)
  }
  func testNativeMenuFocusRingFollowsKeyboardOrPointerOpeningAndRestoration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.appearance.theme = "light"; store.appearance.light.accent = "#0000ff"
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: CodeThemePicker(store: store, dark: false).frame(width: 240, height: 600)
      .background(Color.white).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    let button = try XCTUnwrap(find(host).first), owner = try XCTUnwrap(button.owner)
    let rect = button.convert(button.bounds, to: host), point = CGPoint(x: rect.minX - 1, y: rect.midY)
    for keyboard in [false, true, false] {
      owner.toggle(button, keyboard: keyboard); try await settle(host)
      XCTAssertNotNil(owner.popup)
      owner.dismiss(button, restore: true); try await settle(host)
      XCTAssertTrue(window.firstResponder === button)
      let color = try pixel(host, point: point)
      if keyboard { XCTAssertGreaterThan(color.blueComponent - color.redComponent, 0.3) }
      else { XCTAssertEqual(color.redComponent, 1, accuracy: 3.0 / 255) }
    }
    XCTAssertFalse(window.isVisible)
  }
  private func html(_ value: Any, swatch: Any) -> String {
    if let text = value as? String { return text == "swatch" ? html(swatch, swatch: [:]) : text }
    if let items = value as? [Any] { return items.map { html($0, swatch: swatch) }.joined() }
    guard let node = value as? [String: Any], let props = node["props"] as? [String: Any] else { return "" }
    let type = node["type"] as? String == "button" ? "button" : "span"
    let hidden = props["aria-hidden"] as? Bool == true ? " aria-hidden=\"true\"" : ""
    let disabled = props["disabled"] as? Bool == true ? " disabled" : ""
    return "<\(type) class=\"\(props["className"] as? String ?? "")\"\(hidden)\(disabled)>\(html(props["children"] ?? props["defaultMessage"] ?? "", swatch: swatch))</\(type)>"
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded() }
  private func find(_ view: NSView) -> [SettingsPopupMenuButton.Control] { (view as? SettingsPopupMenuButton.Control).map { [$0] } ?? view.subviews.flatMap(find) }
  private func pixel(_ host: NSView, point: CGPoint) throws -> NSColor {
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
    return try XCTUnwrap(rep.colorAt(x: Int(point.x * CGFloat(rep.pixelsWide) / host.bounds.width), y: Int(point.y * CGFloat(rep.pixelsHigh) / host.bounds.height)))
  }
}
@MainActor private final class AppearanceTriggerNavigationDelegate: NSObject, WKNavigationDelegate {
  let loaded: () -> Void
  init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
