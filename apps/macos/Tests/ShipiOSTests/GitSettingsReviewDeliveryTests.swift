import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitSettingsReviewDeliveryTests: XCTestCase {
  func testNativeGitPageSegmentsChangePersistedReviewDeliveryAndSearchRoutesBackToIt() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host and native SwiftUI accessibility")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.openSettings(.git)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 900),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: GitSettingsView(store: store))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }
    try await settle(host)

    let inline = try XCTUnwrap(element("内联", in: window))
    let detached = try XCTUnwrap(element("单独", in: window))
    XCTAssertEqual(inline.isAccessibilityEnabled?(), true)
    XCTAssertEqual(detached.isAccessibilityEnabled?(), true)
    XCTAssertEqual(store.library.gitPreferences.reviewDelivery, .inline)
    XCTAssertEqual(detached.accessibilityPerformPress?(), true)
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
    XCTAssertNotNil(element("内联", in: window))
    XCTAssertNotNil(element("单独", in: window))
    XCTAssertEqual(store.library.gitPreferences.reviewDelivery, .detached)
  }

  private func settle(_ host: NSView) async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
  }

  private func element(_ label: String, in object: Any) -> AnyObject? {
    guard let node = object as? NSObject else { return nil }
    let dynamic: AnyObject = node
    if dynamic.accessibilityLabel?() == label { return dynamic }
    for child in dynamic.accessibilityChildren?() ?? [] {
      if let found = element(label, in: child) { return found }
    }
    return nil
  }
}
