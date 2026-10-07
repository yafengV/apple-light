import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceAccessibilityTests: XCTestCase {
  func testFullPageNativeLeavesExposeFontMenusNumberInputsAndContrastSliders() async throws {
    let f = try await fixture(); defer { f.window.close() }
    // Hidden windows do not populate SwiftUI's system AX tree. Check the
    // native representable leaves here; the complete tree is verified in-app.
    let nodes = accessibleControls(f.host)
    let labels = nodes.compactMap { $0.accessibilityLabel() }
    for variant in ["浅色", "深色"] {
      for role in ["界面字体", "内容字体", "代码字体"] {
        XCTAssertTrue(labels.contains(variant + role), variant + role)
        XCTAssertTrue(labels.contains(variant + role + "样式"), variant + role + "样式")
      }
      let slider = nodes.first { $0.accessibilityLabel() == variant + " 对比度" }
      XCTAssertEqual(slider?.accessibilityRole(), .slider)
      XCTAssertEqual(slider?.isAccessibilityEnabled(), true)
    }
    for label in ["界面字号", "代码字号"] {
      let field = nodes.first { $0.accessibilityLabel() == label }
      XCTAssertEqual(field?.accessibilityRole(), .incrementor)
    }
    XCTAssertFalse(f.window.isVisible)
  }

  func testDiscoveredNativeControlsApplyFontSizeAndContrastAndPersistActualValues() async throws {
    let f = try await fixture(); defer { f.window.close() }
    let originalDark = f.store.appearance.dark
    let family: SettingsPopupMenuButton.Control = try discover("浅色界面字体", in: f.host)
    XCTAssertTrue(family.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertTrue(SettingsPopupMenuButton.hasOpenMenu(in: f.window))
    try XCTUnwrap(family.owner).choose("family:Menlo", button: family); try await settle(f.host)
    XCTAssertFalse(SettingsPopupMenuButton.hasOpenMenu(in: f.window))
    XCTAssertEqual(f.store.appearance.light.uiFont, "\"Menlo\"")
    XCTAssertTrue(f.window.firstResponder === family)
    let style: SettingsPopupMenuButton.Control = try discover("浅色界面字体样式", in: f.host)
    XCTAssertTrue(style.isAccessibilityEnabled()); XCTAssertTrue(style.accessibilityPerformPress()); try await settle(f.host)
    try XCTUnwrap(style.owner).choose("face:Menlo-Bold", button: style); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.light.uiFace?.postscriptName, "Menlo-Bold")

    let size: AppearanceFontSizeInput.Control = try discover("界面字号", in: f.host)
    let previousSize = f.store.appearance.uiSize
    XCTAssertTrue(size.accessibilityPerformIncrement())
    XCTAssertEqual(f.store.appearance.uiSize, previousSize, "A number input commits on blur or Enter, not on draft stepping")
    XCTAssertTrue(f.window.makeFirstResponder(nil)); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.uiSize, previousSize + 1)

    let slider: AppearanceContrastSlider.Control = try discover("浅色 对比度", in: f.host)
    let previousContrast = f.store.appearance.light.contrast
    XCTAssertEqual(slider.accessibilityMinValue() as? NSNumber, 0)
    XCTAssertEqual(slider.accessibilityMaxValue() as? NSNumber, 100)
    XCTAssertTrue(slider.accessibilityPerformIncrement()); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.light.contrast, previousContrast + 1)
    XCTAssertEqual(slider.accessibilityValue() as? NSNumber, NSNumber(value: previousContrast + 1))
    XCTAssertEqual(f.store.appearance.dark, originalDark)
    XCTAssertEqual(try WorkspaceLibrary.load(from: f.root.appendingPathComponent("workspace.json")).appearance, f.store.appearance)
    XCTAssertEqual(f.store.library.drafts["fixture"], "keep draft")
    XCTAssertFalse(f.window.isVisible)
  }

  func testDiscoveredControlsExposeUnavailableStateRejectActionsAndRecover() async throws {
    let f = try await fixture(); defer { f.window.close() }
    let before = f.store.appearance
    f.store.restoringLibrary = true; try await settle(f.host)
    let family: SettingsPopupMenuButton.Control = try discover("浅色界面字体", in: f.host)
    let size: AppearanceFontSizeInput.Control = try discover("界面字号", in: f.host)
    let slider: AppearanceContrastSlider.Control = try discover("浅色 对比度", in: f.host)
    for control in [family, size, slider] as [NSControl] { XCTAssertFalse(control.isAccessibilityEnabled()) }
    XCTAssertFalse(family.accessibilityPerformPress()); XCTAssertFalse(size.accessibilityPerformIncrement())
    XCTAssertFalse(slider.accessibilityPerformIncrement()); XCTAssertEqual(f.store.appearance, before)
    XCTAssertFalse(SettingsPopupMenuButton.hasOpenMenu(in: f.window))
    f.store.restoringLibrary = false; try await settle(f.host)
    for label in ["浅色界面字体", "界面字号", "浅色 对比度"] {
      let control: NSControl = try discover(label, in: f.host); XCTAssertTrue(control.isAccessibilityEnabled())
    }
    let recovered: AppearanceContrastSlider.Control = try discover("浅色 对比度", in: f.host)
    XCTAssertTrue(recovered.accessibilityPerformIncrement()); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.light.contrast, before.light.contrast + 1)
    XCTAssertFalse(f.window.isVisible)
  }

  private struct Fixture {
    let root: URL; let store: WorkspaceStore; let window: NSWindow; let host: NSView
  }
  private func fixture() async throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-accessibility-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["fixture"] = "keep draft"
    store.destination = .settings; store.settingsPage = .appearance
    await AppearanceFontCatalogSource.shared.load()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 1600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    return .init(root: root, store: store, window: window, host: host)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
  }
  private func discover<T: NSControl>(_ label: String, in host: NSView) throws -> T {
    try XCTUnwrap(accessibleControls(host).first { $0.accessibilityLabel() == label } as? T, label)
  }
  private func accessibleControls(_ host: NSView) -> [NSControl] {
    nativeControls(host).flatMap { NSAccessibility.unignoredChildren(from: [$0]) }.compactMap { $0 as? NSControl }
  }

  private func nativeControls(_ view: NSView) -> [NSControl] {
    ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(nativeControls)
  }
}
