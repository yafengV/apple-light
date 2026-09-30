import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class OpenSourceLicensesTests: XCTestCase {
  func testBundledNoticesReadInNameOrderWithoutUnrelatedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "Second notice".write(to: directory.appendingPathComponent("z-NOTICE.txt"), atomically: true, encoding: .utf8)
    try "First license".write(to: directory.appendingPathComponent("A-MIT.md"), atomically: true, encoding: .utf8)
    try "ignored".write(to: directory.appendingPathComponent("readme.json"), atomically: true, encoding: .utf8)
    let licenses = try OpenSourceLicenses.load(from: directory)
    XCTAssertEqual(licenses.map(\.id), ["A-MIT.md", "z-NOTICE.txt"])
    XCTAssertEqual(licenses.map(\.title), ["A MIT", "z NOTICE"])
    XCTAssertEqual(licenses.map(\.text), ["First license", "Second notice"])
  }

  func testInvalidNoticeReportsErrorInsteadOfPresentingAnEmptyPage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data([0xFF, 0xFE]).write(to: directory.appendingPathComponent("broken.txt"))
    XCTAssertThrowsError(try OpenSourceLicenses.load(from: directory))
  }

  func testLicensePageBackAndSidebarNavigationStayInsideMainSettingsWindow() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.openSettings(.general)
    store.showingOpenSourceLicenses = true
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    XCTAssertTrue(store.closeSettingsFromKeyboard(in: window))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .general)
    XCTAssertFalse(store.showingOpenSourceLicenses)
    store.showingOpenSourceLicenses = true
    store.settingsPage = .notifications
    XCTAssertFalse(store.showingOpenSourceLicenses)
    store.settingsPage = .general
    store.showingOpenSourceLicenses = true
    store.openSettings(.general)
    XCTAssertFalse(store.showingOpenSourceLicenses)
    let result = try XCTUnwrap(SettingsSearch.results(for: "开源许可")
      .first(where: { $0.field == .openSourceLicenses }))
    XCTAssertEqual(result.page, .general)
    store.showingOpenSourceLicenses = true
    store.revealSetting(result)
    XCTAssertFalse(store.showingOpenSourceLicenses)
    XCTAssertEqual(store.settingsSearchRequest?.result.field, .openSourceLicenses)
    store.closeSettings()
    XCTAssertEqual(store.destination, .workspace)
  }

}
