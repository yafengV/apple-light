import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsActionButtonTests: XCTestCase {
  private struct Reference: Decodable {
    struct Expected: Decodable {
      let height, horizontalPadding, borderWidth, fontSize, lineHeight, radius, focusRing: CGFloat
      let disabledOpacity, backgroundOpacity, hoverBackgroundOpacity: Double
    }
    let expected: Expected
    static func load() throws -> Expected {
      let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_action_buttons_reference_667",
        withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).expected
    }
  }

  func testActualButtonUsesPublicToolbarGeometryInBothDirections() async throws {
    let reference = try Reference.load()
    XCTAssertEqual(SettingsActionButtonMetrics.fontSize, reference.fontSize)
    XCTAssertEqual(SettingsActionButtonMetrics.lineHeight, reference.lineHeight)
    XCTAssertEqual(SettingsActionButtonMetrics.radius, reference.radius)
    for rtl in [false, true] {
      let label = NSView(), button = NSView()
      let host = NSHostingView(rootView: Button {} label: {
        Text("恢复默认").background(ActionButtonProbe(view: label))
      }.buttonStyle(SettingsActionButtonStyle(color: .ghost))
        .background(ActionButtonProbe(view: button))
        .padding(20).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
      host.frame.size = .init(width: 200, height: 100); try await settle(host)
      let labelRect = label.convert(label.bounds, to: host), buttonRect = button.convert(button.bounds, to: host)
      XCTAssertEqual(buttonRect.height, reference.height, accuracy: 1)
      XCTAssertEqual(buttonRect.width - labelRect.width,
        2 * (reference.horizontalPadding + reference.borderWidth), accuracy: 1)
      XCTAssertEqual(labelRect.midX, buttonRect.midX, accuracy: 1)
      XCTAssertEqual(labelRect.midY, buttonRect.midY, accuracy: 1)
      let expectedText = ("恢复默认" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: reference.fontSize)])
      XCTAssertEqual(labelRect.width, expectedText.width, accuracy: 2)
    }
  }

  func testRenderedSecondaryAndGhostBackgroundsRespectHoverAndDisabledOpacity() async throws {
    let reference = try Reference.load()
    for (color, hovered, enabled, alpha) in [
      (SettingsActionButtonColor.secondary, false, true, reference.backgroundOpacity),
      (.secondary, true, true, reference.hoverBackgroundOpacity),
      (.secondary, true, false, reference.backgroundOpacity * reference.disabledOpacity),
      (.ghost, false, true, 0), (.ghost, true, false, 0)
    ] {
      let (host, probe) = surface(color: color, hovered: hovered, enabled: enabled)
      try await settle(host)
      let rect = probe.convert(probe.bounds, to: host)
      let pixel = try pixel(host, at: .init(x: rect.midX, y: rect.midY))
      for component in [pixel.redComponent, pixel.greenComponent, pixel.blueComponent] {
        XCTAssertEqual(component, 1 - alpha, accuracy: 2.0 / 255,
          "color=\(color), hovered=\(hovered), enabled=\(enabled)")
      }
    }
  }

  func testFocusRingIsOutsideLayoutAndAbsentForDisabledButtons() async throws {
    let reference = try Reference.load()
    for enabled in [true, false] {
      let (host, probe) = surface(color: .ghost, focused: true, enabled: enabled)
      try await settle(host)
      let rect = probe.convert(probe.bounds, to: host)
      XCTAssertEqual(rect.height, reference.height, accuracy: 1)
      let pixel = try pixel(host, at: .init(x: rect.minX - reference.focusRing / 2, y: rect.midY))
      if enabled { XCTAssertGreaterThan(pixel.blueComponent - pixel.redComponent, 0.3) }
      else { XCTAssertEqual(pixel.redComponent, 1, accuracy: 2.0 / 255) }
      let outside = try self.pixel(host, at: .init(x: rect.minX - reference.focusRing - 1, y: rect.midY))
      XCTAssertEqual(outside.redComponent, 1, accuracy: 2.0 / 255)
    }
  }

  private func surface(color: SettingsActionButtonColor, hovered: Bool = false, focused: Bool = false,
    enabled: Bool = true) -> (NSHostingView<some View>, NSView) {
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.foreground = "#000000"; appearance.light.background = "#ffffff"
    appearance.light.accent = "#0000ff"
    let probe = NSView()
    let host = NSHostingView(rootView: SettingsActionButtonSurface(color: color, hovered: hovered, focused: focused) {
      Color.clear.frame(width: 60, height: 18)
    }.background(ActionButtonProbe(view: probe)).disabled(!enabled)
      .padding(20).background(Color.white).environment(\.appAppearance, appearance))
    host.frame.size = .init(width: 150, height: 100)
    return (host, probe)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
  }
  private func pixel(_ host: NSView, at point: CGPoint) throws -> NSColor {
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * CGFloat(rep.pixelsWide) / host.bounds.width),
      y: Int(point.y * CGFloat(rep.pixelsHigh) / host.bounds.height)))
    // Compare alpha composition in the cache bitmap's own calibrated RGB space.
    // Converting this bitmap to sRGB changes channel values through its ICC curve.
    return color
  }
}

private struct ActionButtonProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
