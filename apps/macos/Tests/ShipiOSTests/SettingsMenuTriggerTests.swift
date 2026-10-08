import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsMenuTriggerTests: XCTestCase {
  private struct Reference: Decodable {
    struct Metrics: Decodable {
      let height, fontSize, lineHeight, padding, swatchSize, swatchPadding, borderWidth, outerGap, innerGap, chevronSize: CGFloat
    }
    let expected: Metrics
    static func load() throws -> Metrics {
      let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_menu_trigger_reference_670",
        withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).expected
    }
  }

  func testActualNativeTriggerUsesPublicGeometryWithAndWithoutSwatchesInBothDirections() async throws {
    let expected = try Reference.load()
    for leading in [false, true] { for rtl in [false, true] {
      let option = SettingsMenuOption(value: 1, title: "Selected", swatch: leading
        ? .init(accent: "#0055ff", foreground: "#000000", background: "#ffffff") : nil)
      let (window, host) = makeHost(SettingsMenuPicker("Menu", selection: .constant(1), options: [option])
        .labelsHidden().fixedSize().padding(20).environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
      defer { window.close() }; try await settle(host)
      let button = try XCTUnwrap(controls(host).first)
      let textWidth = (option.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: expected.fontSize)]).width
      let padding = (leading ? expected.swatchPadding : expected.padding) + expected.padding + expected.borderWidth * 2
      let visual = leading ? expected.swatchSize + expected.innerGap : 0
      XCTAssertEqual(button.bounds.height, expected.height, accuracy: 1)
      XCTAssertEqual(button.bounds.width - textWidth, padding + visual + expected.outerGap + expected.chevronSize, accuracy: 1)
      XCTAssertEqual(button.font?.pointSize, expected.fontSize)
      XCTAssertEqual(button.accessibilityLabel(), "Menu")
      XCTAssertFalse(window.isVisible)
    }}
  }

  func testLongSelectedTitleFitsAvailableWidthWithoutChangingSelectionOrLosingNativeFocusOnResize() async throws {
    let title = String(repeating: "中文选项很长 ", count: 20)
    let (window, host) = makeHost(SettingsMenuPicker("Menu", selection: .constant(1),
      options: [.init(value: 1, title: title)]).labelsHidden().frame(maxWidth: .infinity, alignment: .trailing))
    defer { window.close() }; try await settle(host)
    let button = try XCTUnwrap(controls(host).first)
    XCTAssertTrue(window.makeFirstResponder(button))
    for width in [CGFloat(180), 300, 140] {
      window.setContentSize(.init(width: width, height: 100)); host.frame.size = .init(width: width, height: 100)
      try await settle(host)
      XCTAssertLessThanOrEqual(button.bounds.width, width)
      XCTAssertEqual(button.titleOfSelectedItem, title)
      XCTAssertTrue(window.firstResponder === button)
    }
  }

  func testGitMergeMethodIsAnActualFocusableSharedMenuAndPersistsTheSelectedValue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.openSettings(.git)
    let (window, host) = makeHost(GitSettingsView(store: store)); defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == "默认合并方式" })
    XCTAssertTrue(button.canBecomeKeyView); XCTAssertTrue(window.makeFirstResponder(button))
    XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(button.menu?.items.map(\.title), GitHubPRMergeMethod.allCases.map(\.label))
    let index = try XCTUnwrap(GitHubPRMergeMethod.allCases.firstIndex(of: .squash))
    button.selectItem(at: index); button.sendAction(button.action, to: button.target)
    XCTAssertEqual(store.library.gitPreferences.pullRequestMergeMethod, .squash)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .gitPreferences.pullRequestMergeMethod, .squash)
    let result = try XCTUnwrap(SettingsSearch.results(for: "默认合并方式").first { $0.field == .pullRequestMergeMethod })
    store.openSettings(.general); store.revealSetting(result)
    XCTAssertEqual(store.settingsPage, .git)
  }

  private func makeHost<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view); window.contentView = host
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
  }
  private func controls(_ view: NSView) -> [SettingsMenuControl] {
    (view as? SettingsMenuControl).map { [$0] } ?? view.subviews.flatMap(controls)
  }
}
