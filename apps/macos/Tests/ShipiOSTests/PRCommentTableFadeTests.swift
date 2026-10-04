import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PRCommentTableFadeTests: XCTestCase {
  private let wide = "| " + String(repeating: "W", count: 100) + " | Value |\n|---|---|\n| Cell | 123 |"
  private let short = "| Name | Value |\n|---|---|\n| Alpha | 12 |"
  private func block(_ source: String) throws -> MessageBlock { try XCTUnwrap(MessageDocument.parse(source).first) }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<8 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func configure(_ surface: PRCommentTableScrollView.Surface, source: String, width: CGFloat,
    appearance: AppearancePreferences = .init()) throws {
    surface.configure(block: try block(source), source: source, metrics: .init(appearance: appearance), width: width,
      appearance: appearance, colorScheme: .light, openURL: OpenURLAction { _ in .handled }, imageLoader: nil, revision: "head")
  }
  private func host() async throws -> (NSWindow, NSView, PRCommentTableScrollView.Surface) {
    _ = NSApplication.shared
    let root = NSView(frame: .init(x: 0, y: 0, width: 600, height: 200))
    let region = PRCommentTableScrollView.Surface(frame: .init(x: 10, y: 10, width: 200, height: 160)); root.addSubview(region)
    let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root
    try configure(region, source: wide, width: 200); try await settle(root)
    addTeardownBlock { @MainActor in region.retire(); window.contentView = nil; window.close() }
    return (window, root, region)
  }
  func testFadeLengthsMatchActualPublicCSSComputedStylesIncludingTwoPointAndTinyRanges() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_table_fade_reference.json")
    let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    let states = try XCTUnwrap(facts["states"] as? [[String: Double]])
    for state in states {
      let fade = try XCTUnwrap(PRCommentTableEdgeFade(viewport: try XCTUnwrap(state["viewport"]),
        document: try XCTUnwrap(state["document"]), offset: try XCTUnwrap(state["offset"])))
      XCTAssertEqual(fade.left, try XCTUnwrap(state["left"]), accuracy: 0.0001)
      XCTAssertEqual(fade.right, try XCTUnwrap(state["right"]), accuracy: 0.0001)
    }
  }
  func testGradientStopsFollowCSSFixupBeforeClippingVeryNarrowViewports() throws {
    let narrow = try XCTUnwrap(PRCommentTableEdgeFade(viewport: 10, document: 640, offset: 200))
    XCTAssertEqual(narrow.stops.map(\.position), [0, 1]); XCTAssertEqual(narrow.stops.map(\.alpha), [0, 0.625])
    let meeting = try XCTUnwrap(PRCommentTableEdgeFade(viewport: 32, document: 640, offset: 200))
    XCTAssertEqual(meeting.stops.map(\.position), [0, 0.5, 1]); XCTAssertEqual(meeting.stops.map(\.alpha), [0, 1, 0])
    let start = try XCTUnwrap(PRCommentTableEdgeFade(viewport: 200, document: 640, offset: 0))
    XCTAssertEqual(start.stops.map(\.alpha), [1, 1, 0])
  }
  func testInvalidNonOverflowAndClampedOffsetsRemainFinite() throws {
    XCTAssertNil(PRCommentTableEdgeFade(viewport: 200, document: 200, offset: 0))
    XCTAssertNil(PRCommentTableEdgeFade(viewport: 0, document: 640, offset: 0))
    XCTAssertNil(PRCommentTableEdgeFade(viewport: .nan, document: 640, offset: 0))
    XCTAssertNil(PRCommentTableEdgeFade(viewport: 200, document: .infinity, offset: 0))
    XCTAssertNil(PRCommentTableEdgeFade(viewport: 200, document: 640, offset: .nan))
    XCTAssertNil(PRCommentTableEdgeFade(viewport: 200, document: 640, offset: 0, distance: -1))
    let before = try XCTUnwrap(PRCommentTableEdgeFade(viewport: 200, document: 640, offset: -10))
    XCTAssertEqual(before.left, 0); XCTAssertEqual(before.right, 16)
    let after = try XCTUnwrap(PRCommentTableEdgeFade(viewport: 200, document: 640, offset: 900))
    XCTAssertEqual(after.left, 16); XCTAssertEqual(after.right, 0)
  }
  func testActualClipBoundsNotificationsAndCopyPageScrollingUpdateMaskWithoutParentOverlay() async throws {
    let (_, root, region) = try await host()
    XCTAssertEqual(try XCTUnwrap(region.edgeFade).left, 0); XCTAssertEqual(try XCTUnwrap(region.edgeFade).right, 16)
    let layer = try XCTUnwrap(region.layer?.mask as? CAGradientLayer)
    XCTAssertEqual(layer.frame, region.bounds); XCTAssertNil(root.layer?.mask)
    region.contentView.scroll(to: .init(x: 2, y: 0))
    XCTAssertEqual(try XCTUnwrap(region.edgeFade).left, 0)
    region.contentView.scroll(to: .init(x: 3, y: 0))
    XCTAssertEqual(try XCTUnwrap(region.edgeFade).left, 16); XCTAssertEqual(try XCTUnwrap(region.edgeFade).right, 16)
    let target = PRCommentTableScrollTarget(); target.anchor = region.anchor
    XCTAssertTrue(target.scroll(40, page: true)); XCTAssertEqual(region.contentView.bounds.minX, 203, accuracy: 0.1)
    let end = region.document.bounds.width - region.contentView.bounds.width
    region.contentView.scroll(to: .init(x: end - 2, y: 0))
    XCTAssertEqual(try XCTUnwrap(region.edgeFade).right, 0)
    XCTAssertNil(layer.animationKeys(), "Scroll-position masks do not lag behind implicit Core Animation transitions")
  }
  func testResizeSourceReplacementDetachAndRetireRemoveStaleMasks() async throws {
    let (window, root, region) = try await host()
    var appearance = AppearancePreferences(); appearance.theme = "dark"
    try configure(region, source: wide, width: 200, appearance: appearance); try await settle(root)
    XCTAssertNotNil(region.layer?.mask)
    region.frame.size.width = 650
    try configure(region, source: wide, width: 650); try await settle(root)
    XCTAssertNil(region.edgeFade); XCTAssertNil(region.layer?.mask)
    region.frame.size.width = 200
    try configure(region, source: wide, width: 200); try await settle(root); XCTAssertNotNil(region.layer?.mask)
    try configure(region, source: short, width: 200); try await settle(root); XCTAssertNil(region.layer?.mask)
    try configure(region, source: wide, width: 200); try await settle(root); XCTAssertNotNil(region.layer?.mask)
    window.contentView = nil; XCTAssertNil(region.layer?.mask)
    window.contentView = root; try await settle(root); XCTAssertNotNil(region.layer?.mask)
    region.retire(); region.contentView.scroll(to: .init(x: 100, y: 0))
    XCTAssertNil(region.edgeFade); XCTAssertNil(region.layer?.mask)
  }
  func testInstalledGradientRasterHasLinearAlphaEdgesAndOpaqueCenter() async throws {
    let (_, _, region) = try await host()
    region.contentView.scroll(to: .init(x: 40, y: 0))
    let layer = try XCTUnwrap(region.layer?.mask as? CAGradientLayer)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 160,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    layer.render(in: graphics.cgContext)
    func alpha(_ x: Int) throws -> CGFloat { try XCTUnwrap(bitmap.colorAt(x: x, y: 80)).alphaComponent }
    XCTAssertEqual(try alpha(0), 0.5 / 16, accuracy: 0.02)
    XCTAssertEqual(try alpha(7), 7.5 / 16, accuracy: 0.02)
    XCTAssertEqual(try alpha(16), 1, accuracy: 0.01)
    XCTAssertEqual(try alpha(100), 1, accuracy: 0.01)
    XCTAssertEqual(try alpha(199), 0.5 / 16, accuracy: 0.02)
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_TABLE_FADE_RENDER_DIR"] {
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("middle-mask.png"))
      // Separate visualization of the same installed mask on an opaque white background.
      graphics.cgContext.setFillColor(NSColor.white.cgColor); graphics.cgContext.fill(.init(x: 0, y: 0, width: 200, height: 160))
      layer.render(in: graphics.cgContext)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("middle-mask-on-white.png"))
    }
  }
}
