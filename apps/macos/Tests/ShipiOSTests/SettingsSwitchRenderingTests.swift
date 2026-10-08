import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class SettingsSwitchRenderingTests: XCTestCase {
  func testActualPublicVariantsGuardDisabledAndPreventedClicks() throws {
    let fixture = try reference(), cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 16); XCTAssertEqual(fixture["duration"] as? Double, 0.15)
    for item in cases {
      let checked = try XCTUnwrap(item["checked"] as? Bool), disabled = try XCTUnwrap(item["disabled"] as? Bool)
      XCTAssertEqual(item["changes"] as? [Bool], disabled ? [] : [!checked])
      XCTAssertEqual(item["preventedChanges"] as? [Bool], [])
    }
  }
  func testFullStylesheetResolvesActualTrackThumbRTLAndDisabledGeometry() async throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] else { throw XCTSkip("Set SHIPIOS_REFERENCE_CSS for the pinned stylesheet") }
    let fixture = try reference(), hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String])
    let data = try Data(contentsOf: URL(fileURLWithPath: path)), css = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[1])
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    let sections = try ["ltr", "rtl"].flatMap { direction in try cases.map { item in
      "<section dir=\"\(direction)\">\(html(try XCTUnwrap(item["tree"])))</section>"
    } }.joined()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 850, height: 900)), loaded = expectation(description: "Actual switch variants")
    let delegate = SwitchNavigationDelegate { loaded.fulfill() }; web.navigationDelegate = delegate
    web.loadHTMLString("<!doctype html><html data-codex-window-type=\"electron\"><style>\(css)</style><body>\(sections)</body></html>", baseURL: nil)
    await fulfillment(of: [loaded], timeout: 10)
    let raw = try await web.evaluateJavaScript("""
      [...document.querySelectorAll('section')].map(section=>{const root=section.firstElementChild,track=root.firstElementChild,thumb=track.firstElementChild,r=track.getBoundingClientRect(),t=thumb.getBoundingClientRect();
        return {width:r.width,height:r.height,thumbWidth:t.width,thumbHeight:t.height,x:t.x-r.x,y:t.y-r.y,opacity:parseFloat(getComputedStyle(root).opacity),duration:getComputedStyle(track).transitionDuration}})
      """)
    let results = try XCTUnwrap(raw as? [[String: Any]]); XCTAssertEqual(results.count, 32)
    for (index, item) in results.enumerated() {
      let original = cases[index % cases.count], checked = try XCTUnwrap(original["checked"] as? Bool), small = original["size"] as? String == "sm"
      let rtl = index >= cases.count, expectedX = checked != rtl ? 14.0 : 2.0
      XCTAssertEqual(item["width"] as? Double, small ? 28 : 32); XCTAssertEqual(item["height"] as? Double, small ? 16 : 20)
      XCTAssertEqual(item["thumbWidth"] as? Double, small ? 12 : 16); XCTAssertEqual(item["thumbHeight"] as? Double, small ? 12 : 16)
      XCTAssertEqual(item["x"] as? Double, expectedX); XCTAssertEqual(item["y"] as? Double, 2)
      XCTAssertEqual(item["opacity"] as? Double, original["disabled"] as? Bool == true ? 0.6 : 1)
      XCTAssertEqual(item["duration"] as? String, "0.15s")
    }
  }
  func testFocusRingEndsTwoPointsOutsideWithoutAnExtraGap() throws {
    let bitmap = try render(on: false, enabled: true, focused: true)
    XCTAssertGreaterThan(try pixel(bitmap, x: 26, y: 7.5).greenComponent, 0.98, "Outside the two-point ring must stay clear")
    XCTAssertLessThan(try pixel(bitmap, x: 26, y: 9.5).greenComponent, 0.2, "The ring touches the track instead of leaving a one-point gap")
  }
  func testDarkFocusUsesTheDerivedFocusRoleInsteadOfRawAccent() throws {
    var appearance = palette(); appearance.theme = "dark"; appearance.dark.accent = "#FF0000"
    let bitmap = try render(on: false, enabled: true, focused: true, appearance: appearance)
    let color = try pixel(bitmap, x: 26, y: 9.5)
    XCTAssertGreaterThan(color.greenComponent, 0.2); XCTAssertGreaterThan(color.blueComponent, 0.2)
    let expected = appearance.resolvedColors["borderFocus"]
    XCTAssertEqual(color.greenComponent, 1 - expected.alpha + Double(expected.green) / 255 * expected.alpha, accuracy: 0.04)
  }
  func testDefaultThumbRetainsIts14And2PointOffsetsInBothDirections() throws {
    for rtl in [false, true] { for on in [false, true] {
      let bitmap = try render(on: on, enabled: true, focused: false, rtl: rtl)
      let center = on != rtl ? 22.0 : 10.0
      XCTAssertGreaterThan(try pixel(bitmap, x: 10 + center, y: 20).greenComponent, 0.98)
      let other = try pixel(bitmap, x: 10 + (center == 22 ? 4 : 28), y: 20)
      XCTAssertLessThan(other.greenComponent, on ? 0.1 : 0.95)
    } }
  }
  func testDisabledStateDimsOnlyTheSwitchAndHidesItsFocusRing() throws {
    let bitmap = try render(on: true, enabled: false, focused: true)
    XCTAssertGreaterThan(try pixel(bitmap, x: 26, y: 9).greenComponent, 0.98)
    XCTAssertEqual(try pixel(bitmap, x: 14, y: 20).greenComponent, 0.4, accuracy: 0.03)
  }
  private func palette() -> AppearancePreferences { var value = AppearancePreferences(); value.theme = "light"; value.light.accent = "#FF0000"; return value }
  private func render(on: Bool, enabled: Bool, focused: Bool, rtl: Bool = false, appearance: AppearancePreferences? = nil) throws -> NSBitmapImageRep {
    let renderer = ImageRenderer(content: SettingsSwitchSurface(isOn: on, isEnabled: enabled, focused: focused)
      .environment(\.appAppearance, appearance ?? palette()).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
      .padding(10).background(Color.white)); renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage), bitmap = NSBitmapImageRep(cgImage: image)
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("switch-\(on)-\(enabled)-\(focused)-\(rtl).png"))
    }
    return bitmap
  }
  private func pixel(_ bitmap: NSBitmapImageRep, x: Double, y: Double) throws -> NSColor {
    // ImageRenderer supplies sRGB bytes. colorAt labels them calibrated RGB;
    // converting that label again changes pure red to a nonzero green channel.
    XCTAssertEqual(bitmap.colorSpace, .sRGB)
    return try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2)))
  }
  private func reference() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_switch_reference_675", withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  private func html(_ value: Any) -> String {
    guard let node = value as? [String: Any], let props = node["props"] as? [String: Any] else { return "" }
    let tag = node["type"] as? String ?? "span", state = props["data-state"] as? String ?? ""
    return "<\(tag) class=\"\(props["className"] as? String ?? "")\" data-state=\"\(state)\"\(props["disabled"] as? Bool == true ? " disabled" : "")>\(props["children"].map(html) ?? "")</\(tag)>"
  }
}
@MainActor private final class SwitchNavigationDelegate: NSObject, WKNavigationDelegate {
  let loaded: () -> Void
  init(_ loaded: @escaping () -> Void) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
}
