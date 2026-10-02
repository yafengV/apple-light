import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitSettingsReviewDeliveryTests: XCTestCase {
  func testGitPagePickerChangesPersistedReviewDeliveryAndSearchRoutesBackToIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.openSettings(.git)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: GitSettingsView(store: store))
    window.contentView = host
    defer { window.close() }
    try await settle(host)

    let picker = try XCTUnwrap(findReviewDeliveryPicker(host))
    XCTAssertEqual(picker.menu?.items.map(\.title), ["内联", "单独"])
    XCTAssertEqual(picker.titleOfSelectedItem, "内联")
    XCTAssertTrue(picker.active)
    XCTAssertTrue(picker.isEnabled)
    XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
    picker.selectItem(at: 1)
    picker.sendAction(picker.action, to: picker.target)
    XCTAssertEqual(store.library.gitPreferences.reviewDelivery, .detached)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .gitPreferences.reviewDelivery, .detached)

    let result = try XCTUnwrap(SettingsSearch.results(for: "审查结果呈现方式")
      .first { $0.field == .reviewDelivery })
    XCTAssertEqual(result.field, .reviewDelivery)
    XCTAssertEqual(result.page, .git)
    store.openSettings(.general)
    store.revealSetting(result)
    XCTAssertEqual(store.settingsPage, .git)
    XCTAssertEqual(store.settingsSearchRequest?.result.field, .reviewDelivery)

    try await settle(host)
    XCTAssertEqual(picker.titleOfSelectedItem, "单独")
  }

  private func settle(_ host: NSView) async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
  }

  private func findReviewDeliveryPicker(_ view: NSView) -> SettingsMenuControl? {
    if let control = view as? SettingsMenuControl,
       control.accessibilityLabel() == "审查结果呈现方式" { return control }
    return view.subviews.lazy.compactMap(findReviewDeliveryPicker).first
  }
}
