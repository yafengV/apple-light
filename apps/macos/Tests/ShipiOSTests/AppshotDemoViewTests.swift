import AppKit
import SwiftUI
import XCTest

@testable import ShipiOS

final class AppshotDemoViewTests: XCTestCase {
  @MainActor func testDemoRendersAtReferenceAspectRatio() throws {
    let width: CGFloat = 360
    let height = width * 1095 / 901
    let renderer = ImageRenderer(content: AppshotDemoView().frame(width: width, height: height))
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.nsImage)
    XCTAssertEqual(image.size.width, width, accuracy: 1)
    XCTAssertEqual(image.size.height, height, accuracy: 1)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_APPSHOT_DEMO_RENDER_PATH"] {
      let tiff = try XCTUnwrap(image.tiffRepresentation)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
  }

  @MainActor func testSettingsPageRendersHeroControlsAndDemo() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 768, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AppshotSettingsView(store: store)
      .environment(\.appAppearance, store.appearance))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(500))
    host.needsLayout = true
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    XCTAssertEqual(host.bounds.width, 768, accuracy: 1)
    let filledSamples = stride(from: 20, through: 680, by: 20).reduce(0) { count, y in
      count + stride(from: 20, through: 740, by: 20).filter { x in
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          return false
        }
        return min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9
      }.count
    }
    XCTAssertGreaterThan(filledSamples, 100, "Settings page should render visible content")
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_APPSHOT_SETTINGS_RENDER_PATH"] {
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    window.close()
    await store.shutdown()
  }
}
