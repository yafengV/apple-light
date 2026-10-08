import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class VoiceDictionaryNativeControlTests: XCTestCase {
  func testOffscreenNativeButtonFocusRevealsWithoutInsertingAndDoesNotReplayAfterLostFocus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.voicePreferences.dictationDictionary = ["Saved"]
    var reveals: [UUID] = []
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: ScrollViewReader { proxy in
      ScrollView {
        VStack {
          Color.clear.frame(height: 700)
          VoiceDictionarySettingsCard(store: store)
          Color.clear.frame(height: 100)
        }
      }.environment(\.settingsRevealFocusedControl, { id in reveals.append(id); proxy.scrollTo(id) })
        .environment(\.appAppearance, store.appearance)
    }.frame(width: 600, height: 240))
    window.contentView = host; try await settle(host)
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictionaryActionButton.Control }.first { $0.accessibilityIdentifier() == "voice-dictionary-add" })
    // Installing content can pick its first key view. Establish a top viewport
    // with no focused dictionary control before testing an offscreen focus.
    window.makeFirstResponder(nil)
    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    try await settle(host); reveals.removeAll()
    XCTAssertEqual(button.bounds.intersection(button.visibleRect).height, 0,
      "Initial bounds \(button.bounds), visible \(button.visibleRect), document \(String(describing: scroll.documentView?.frame))")
    XCTAssertTrue(window.makeFirstResponder(button)); try await settle(host)
    XCTAssertGreaterThan(reveals.count, 0)
    XCTAssertGreaterThanOrEqual(button.bounds.intersection(button.visibleRect).height, button.bounds.height - 1)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, ["Saved"])
    XCTAssertEqual(descendants(host).compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "Jane Doe" }.count, 1)
    let count = reveals.count
    window.makeFirstResponder(nil)
    XCTAssertTrue(window.makeFirstResponder(button)); window.makeFirstResponder(nil)
    try await settle(host); XCTAssertEqual(reveals.count, count)
    XCTAssertFalse(window.isVisible)
  }

  func testNativePerformClickActivatesLatestDictionaryAction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: VoiceDictionarySettingsCard(store: store).environment(\.appAppearance, store.appearance))
    window.contentView = host; try await settle(host)
    let add = try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictionaryActionButton.Control }.first { $0.accessibilityIdentifier() == "voice-dictionary-add" })
    add.performClick(nil); try await settle(host)
    XCTAssertEqual(descendants(host).compactMap { $0 as? NSTextField }.filter { ["Jane Doe", "Acme Widget"].contains($0.placeholderString ?? "") }.count, 2)
    XCTAssertEqual(store.voicePreferences.dictationDictionary, [])
  }

  func testNativeButtonReceivesRightToLeftEnvironment() async throws {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: VoiceDictionaryActionButton(title: "添加词条", label: "添加词条", identifier: "rtl-add", action: {})
      .fixedSize().environment(\.layoutDirection, .rightToLeft).disabled(true))
    window.contentView = host; try await settle(host)
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? VoiceDictionaryActionButton.Control }.first)
    XCTAssertEqual(button.userInterfaceLayoutDirection, .rightToLeft)
    XCTAssertFalse(button.isEnabled); XCTAssertFalse(button.acceptsFirstResponder)
    XCTAssertFalse(button.accessibilityPerformPress())
  }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded() }
}
