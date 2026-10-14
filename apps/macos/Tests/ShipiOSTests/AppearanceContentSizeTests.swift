import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceContentSizeTests: XCTestCase {
  func testLegacyMigrationPreservesScaleThenSeparatesUIAndContent() throws {
    var legacy = try JSONDecoder().decode(AppearancePreferences.self, from: Data(#"{"uiSize":16,"codeSize":12}"#.utf8))
    XCTAssertEqual(legacy.contentSize, 16)
    legacy.uiSize = 11
    XCTAssertEqual(legacy.nativeFont(size: 14).pointSize, 11)
    XCTAssertEqual(legacy.nativeFont(size: 14, content: true).pointSize, 16)
    XCTAssertEqual(legacy.nativeFont(size: 12, code: true).pointSize, 12)
    let restored = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(legacy))
    XCTAssertEqual(restored.uiSize, 11); XCTAssertEqual(restored.contentSize, 16)
    XCTAssertEqual(try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8)).contentSize, 14)
  }

  func testIndependentScaleBoundsThemeFileAndAdvancedReset() throws {
    var value = AppearancePreferences(); value.uiSize = 16; value.contentSize = 18.5; value.codeSize = 10.5
    XCTAssertEqual(value.nativeFont(size: 14, content: true).pointSize, 19)
    XCTAssertEqual(value.nativeFont(size: 28, content: true).pointSize, 37)
    XCTAssertEqual(value.nativeFont(size: 12, code: true, content: true).pointSize, 10.5)
    let decoded = try AppearanceThemeFile.decode(JSONEncoder().encode(AppearanceThemeFile(appearance: value)))
    XCTAssertEqual(decoded, value)
    XCTAssertTrue(value.hasAdvancedChanges)
    XCTAssertEqual(value.resettingAdvanced().contentSize, 14)
    XCTAssertFalse(value.resettingAdvanced().hasAdvancedChanges)
    value.contentSize = .infinity; XCTAssertEqual(value.normalized().contentSize, 14)
    value.contentSize = 100; XCTAssertEqual(value.normalized().contentSize, 24)
    value.contentSize = -1; XCTAssertEqual(value.normalized().contentSize, 8)
    XCTAssertEqual(AppearanceFontSize.content.committed("25", current: 18.5), 18.5)
    XCTAssertEqual(AppearanceFontSize.content.committed("18.5", current: 14), 18.5)
  }

  func testMountedContentControlCommitsIndependentlyAndReloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.drafts["keep"] = "unchanged"
    let presentation = AppearancePagePresentation(advancedExpanded: true)
    let host = NSHostingView(rootView: AppearanceSettingsView(store: store, presentation: presentation))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100))
    func fields(_ view: NSView) -> [AppearanceFontSizeInput.Control] {
      (view as? AppearanceFontSizeInput.Control).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let field = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "内容字体大小" })
    XCTAssertEqual(fields(host).count, 3)
    field.stringValue = "18.5"; try XCTUnwrap(field.owner).commit(field)
    XCTAssertEqual(store.appearance.contentSize, 18.5)
    XCTAssertEqual(store.appearance.uiSize, 14); XCTAssertEqual(store.appearance.codeSize, 12)
    var next = store.appearance; next.uiSize = 11; XCTAssertTrue(store.commitAppearance(next))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.appearance?.contentSize, 18.5); XCTAssertEqual(restored.appearance?.uiSize, 11)
    XCTAssertEqual(restored.drafts["keep"], "unchanged")
    XCTAssertTrue(SettingsSearch.results(for: "内容字体大小").contains { $0.field == .contentFontSize && $0.page == .appearance })
    XCTAssertEqual(PRCommentTableMetrics(appearance: next).baseSize, 17)
    XCTAssertFalse(window.isVisible)
  }
}
