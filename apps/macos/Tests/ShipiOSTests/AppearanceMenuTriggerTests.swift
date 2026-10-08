import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceMenuTriggerTests: XCTestCase {
  private struct Reference: Decodable {
    struct Metrics: Decodable { let height, fontSize, codeFontSize, codeWidth, codeSwatchSize: CGFloat }
    let metrics: Metrics
    static func load() throws -> Metrics {
      let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_menu_trigger_reference_671", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).metrics
    }
  }
  func testCodeThemeTriggerContainsItsSwatchWithinThePublic176PointWidth() async throws {
    let expected = try Reference.load(), store = store()
    let (window, host) = host(CodeThemePicker(store: store, dark: false).fixedSize())
    defer { window.close() }; try await settle(host)
    let button = try XCTUnwrap(find(host, SettingsPopupMenuButton.Control.self).first)
    XCTAssertEqual(host.fittingSize.width, expected.codeWidth, accuracy: 1)
    XCTAssertEqual(button.font?.pointSize, expected.codeFontSize)
    XCTAssertEqual(button.frame.height, expected.height)
    XCTAssertEqual(button.accessibilityLabel(), "浅色代码主题")
    XCTAssertTrue(window.makeFirstResponder(button)); XCTAssertTrue(window.firstResponder === button)
  }
  func testThemeSwatchUsesThePublicCircularShapeAtTriggerAndMenuSizes() throws {
    for size: CGFloat in [20, 24] {
      let renderer = ImageRenderer(content: ThemeColorSwatch(swatch: .init(accent: "#0000ff", foreground: "#000000", background: "#ff0000"), size: size)); renderer.scale = 1
      let image = try XCTUnwrap(renderer.cgImage), rep = NSBitmapImageRep(cgImage: image)
      XCTAssertEqual(image.width, Int(size))
      XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 2, y: 1)).alphaComponent, 0.1)
      XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: Int(size)/2, y: 3)).alphaComponent, 0.9)
    }
  }
  func testAccentUsesMenuRowTypographyAndRetainsAnIndependentAccessibleMenu() async throws {
    let expected = try Reference.load(), store = store()
    let (window, host) = host(AppearanceAccentPicker(store: store, dark: false).frame(width: 500, height: 500))
    defer { window.close() }; try await settle(host)
    let button = try XCTUnwrap(find(host, SettingsPopupMenuButton.Control.self).first)
    XCTAssertEqual(button.font?.pointSize, expected.fontSize)
    XCTAssertEqual(button.frame.height, expected.height)
    XCTAssertEqual(button.accessibilityLabel(), "浅色强调色")
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(host)
    XCTAssertTrue(owner.popup?.window === window)
    owner.dismiss(button, restore: true); try await settle(host)
    XCTAssertTrue(window.firstResponder === button)
  }
  private func store() -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    return store
  }
  private func host<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host
    return (window, host)
  }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded() }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) }
  }
}
