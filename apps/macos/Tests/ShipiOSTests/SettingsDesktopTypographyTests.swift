import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class SettingsDesktopTypographyTests: XCTestCase {
  func testActualPublicCSSCascadeResolvesDesktopOverridesInsteadOfThemeDefaults() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_desktop_typography_reference_669",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let css: String
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_REFERENCE_CSS"] {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), reference.sourceSHA256[1])
      css = try XCTUnwrap(String(data: data, encoding: .utf8))
    } else { css = reference.referenceCSS }
    for desktop in [false, true] {
      let values = try await computed(css: css, desktop: desktop, classes: reference.componentClasses)
      XCTAssertEqual(try XCTUnwrap(values["labelSize"]), desktop ? reference.expected.labelFontSize : 12, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(values["descriptionSize"]), desktop ? reference.expected.descriptionFontSize : 11, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(values["labelLineHeight"]), desktop ? reference.expected.labelLineHeight : 120.0 / 7, accuracy: 0.01)
      XCTAssertEqual(try XCTUnwrap(values["descriptionLineHeight"]), reference.expected.descriptionLineHeight, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(values["buttonSize"]), desktop ? reference.expected.fontSize : 12, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(values["buttonLineHeight"]), reference.expected.lineHeight, accuracy: 0.001)
    }
  }

  private func computed(css: String, desktop: Bool, classes: [String: String]) async throws -> [String: Double] {
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 600, height: 300))
    let loaded = expectation(description: "Public CSS document loaded")
    let delegate = TypographyNavigationDelegate { loaded.fulfill() }
    web.navigationDelegate = delegate
    XCTAssertFalse(css.contains("</style"))
    web.loadHTMLString("""
      <!doctype html><html \(desktop ? "data-codex-window-type=electron" : "")>
      <head><style>\(css)</style></head><body>
      <span id="label" class="\(classes["label"] ?? "")">Setting</span>
      <span id="description" class="\(classes["description"] ?? "")">Description</span>
      <button id="button" class="\(classes["button"] ?? "")">Action</button>
      </body></html>
      """, baseURL: nil)
    await fulfillment(of: [loaded], timeout: 10)
    let result = try await web.evaluateJavaScript("""
      (() => {const style = id => getComputedStyle(document.getElementById(id));
      return {labelSize:parseFloat(style('label').fontSize),
        labelLineHeight:parseFloat(style('label').lineHeight),
        descriptionSize:parseFloat(style('description').fontSize),
        descriptionLineHeight:parseFloat(style('description').lineHeight),
        buttonSize:parseFloat(style('button').fontSize),
        buttonLineHeight:parseFloat(style('button').lineHeight)}})()
      """)
    return try XCTUnwrap(result as? [String: Double])
  }
  private struct Reference: Decodable {
    struct Expected: Decodable {
      let labelFontSize, descriptionFontSize, labelLineHeight, descriptionLineHeight, fontSize, lineHeight: Double
    }
    let referenceCSS: String
    let sourceSHA256: [String]
    let componentClasses: [String: String]
    let expected: Expected
  }
}

@MainActor private final class TypographyNavigationDelegate: NSObject, WKNavigationDelegate {
  let finished: () -> Void
  init(finished: @escaping () -> Void) { self.finished = finished }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished() }
}
