import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class SettingsMenuTriggerRenderingTests: XCTestCase {
  func testFullPublicCSSResolvesDefaultAndLeadingTriggerGeometryAndOpenColor() async throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] else {
      throw XCTSkip("Set SHIPIOS_REFERENCE_CSS to verify the pinned full public stylesheet")
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_menu_trigger_reference_670", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String])
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[2])
    let css = try XCTUnwrap(String(data: data, encoding: .utf8))
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    let expected = try XCTUnwrap(fixture["expected"] as? [String: Double])
    for index in [0, 2] {
      let tree = try XCTUnwrap(cases[index]["tree"] as? [String: Any])
      let props = try XCTUnwrap(tree["props"] as? [String: Any])
      let classes = try XCTUnwrap(props["className"] as? String)
      let web = WKWebView(frame: .init(x: 0, y: 0, width: 500, height: 200))
      let loaded = expectation(description: "Public form trigger loaded")
      let delegate = MenuTriggerNavigationDelegate { loaded.fulfill() }; web.navigationDelegate = delegate
      web.loadHTMLString("""
        <!doctype html><html data-codex-window-type="electron"><head><style>\(css)</style>
        <style>:root{--app-color-background-elevated-secondary:#112233;--app-color-background-button-secondary-hover:#445566}</style>
        </head><body><button id="trigger" class="\(classes)">Selected option</button>
        <span id="chevron" class="icon-2xs"></span></body></html>
        """, baseURL: nil)
      await fulfillment(of: [loaded], timeout: 10)
      let raw = try await web.evaluateJavaScript("""
        (() => {const button=document.getElementById('trigger'), s=getComputedStyle(button);
        const value={height:parseFloat(s.height),fontSize:parseFloat(s.fontSize),lineHeight:parseFloat(s.lineHeight),
        left:parseFloat(s.paddingLeft),right:parseFloat(s.paddingRight),border:parseFloat(s.borderLeftWidth),
        gap:parseFloat(s.columnGap),chevron:parseFloat(getComputedStyle(document.getElementById('chevron')).width),
        background:s.backgroundColor};button.setAttribute('data-state','open');value.open=getComputedStyle(button).backgroundColor;return value})()
        """)
      let values = try XCTUnwrap(raw as? [String: Any])
      for (actual, key) in [("height", "height"), ("fontSize", "fontSize"), ("lineHeight", "lineHeight"),
        ("right", "padding"), ("border", "borderWidth"), ("gap", "outerGap"), ("chevron", "chevronSize")] {
        XCTAssertEqual(try XCTUnwrap(values[actual] as? Double), try XCTUnwrap(expected[key]), accuracy: 0.01, actual)
      }
      XCTAssertEqual(try XCTUnwrap(values["left"] as? Double), try XCTUnwrap(expected[index == 0 ? "padding" : "swatchPadding"]), accuracy: 0.01)
      XCTAssertEqual(values["background"] as? String, "rgb(17, 34, 51)")
      XCTAssertEqual(values["open"] as? String, "rgb(68, 85, 102)")
    }
  }

  func testActualNativeSurfaceUsesDesktopColorsDuringMenuTrackingAndDisabledState() async throws {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.background = "#ffffff"; appearance.light.foreground = "#000000"; appearance.light.accent = "#0000ff"
    let (window, host) = makeHost(appearance); defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(control(host)), menu = try XCTUnwrap(button.menu)
    let expected = appearance.resolvedColors
    func verify(_ role: String, opacity: Double = 1) throws {
      let rect = button.convert(button.bounds, to: host)
      let value = try pixel(host, point: .init(x: rect.minX + 6, y: rect.midY))
      let color = expected[role]
      for (actual, channel) in [(value.redComponent, color.red), (value.greenComponent, color.green), (value.blueComponent, color.blue)] {
        XCTAssertEqual(actual, CGFloat(1 + (Double(channel) / 255 - 1) * color.alpha * opacity), accuracy: 3.0 / 255, role)
      }
    }
    try verify("elevatedSecondary")
    let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    button.mouseEntered(with: entered); try await settle(host)
    try verify("buttonSecondaryBackgroundHover")
    let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    button.mouseExited(with: exited); try await settle(host)
    try verify("elevatedSecondary")
    menu.delegate?.menuWillOpen?(menu); try await settle(host)
    try verify("buttonSecondaryBackgroundHover")
    menu.delegate?.menuDidClose?(menu); try await settle(host)
    try verify("elevatedSecondary")
    XCTAssertTrue(window.makeFirstResponder(button)); try await settle(host)
    let rect = button.convert(button.bounds, to: host)
    let focused = try pixel(host, point: .init(x: rect.minX - 1, y: rect.midY))
    XCTAssertGreaterThan(focused.blueComponent - focused.redComponent, 0.3)
    button.isEnabled = false; try await settle(host)
    try verify("elevatedSecondary", opacity: 0.4)
    XCTAssertFalse(window.firstResponder === button)
    let disabled = try pixel(host, point: .init(x: rect.minX - 1, y: rect.midY))
    XCTAssertEqual(disabled.redComponent, 1, accuracy: 3.0 / 255)
    XCTAssertFalse(window.isVisible)
  }
  private func makeHost(_ appearance: AppearancePreferences) -> (NSWindow, NSHostingView<some View>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: SettingsMenuPicker("Menu", selection: .constant(1), options: [.init(value: 1, title: "Selected")])
      .labelsHidden().fixedSize().padding(20).background(Color.white).environment(\.appAppearance, appearance))
    window.contentView = host; return (window, host)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded() }
  private func control(_ view: NSView) -> SettingsMenuControl? {
    (view as? SettingsMenuControl) ?? view.subviews.lazy.compactMap(control).first
  }
  private func pixel(_ host: NSView, point: CGPoint) throws -> NSColor {
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep)
    return try XCTUnwrap(rep.colorAt(x: Int(point.x * CGFloat(rep.pixelsWide) / host.bounds.width),
      y: Int(point.y * CGFloat(rep.pixelsHigh) / host.bounds.height)))
  }
}
@MainActor private final class MenuTriggerNavigationDelegate: NSObject, WKNavigationDelegate {
  let loaded: () -> Void
  init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
