import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class MessageLinkPointerTests: XCTestCase {
  private let first = URL(string: "https://example.invalid/first")!
  private let second = URL(string: "https://example.invalid/second")!

  private func event(_ type: NSEvent.EventType, point: NSPoint = .init(x: 15, y: 15),
    flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    if type == .otherMouseDown || type == .rightMouseDown {
      let event = try XCTUnwrap(CGEvent(mouseEventSource: nil,
        mouseType: type == .otherMouseDown ? .otherMouseDown : .rightMouseDown,
        mouseCursorPosition: point, mouseButton: type == .otherMouseDown ? .center : .right))
      event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
      return try XCTUnwrap(NSEvent(cgEvent: event))
    }
    return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }

  func testMouseButtonMappingAndOnlyLinkGesturesAreIntercepted() throws {
    let view = MessageLinkPointerTarget.TargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    view.regions = [.init(url: first, rect: .init(x: 10, y: 10, width: 30, height: 20))]
    view.actions = .init(activate: { _, _ in }, perform: { _, _ in })
    let inside = NSPoint(x: 15, y: 15)
    XCTAssertFalse(view.captures(try event(.leftMouseDown), at: inside), "Ordinary selection remains native Text")
    XCTAssertTrue(view.captures(try event(.leftMouseDown, flags: .option), at: inside))
    XCTAssertTrue(view.captures(try event(.rightMouseDown), at: inside))
    XCTAssertFalse(view.captures(try event(.rightMouseDown), at: .init(x: 60, y: 15)))
    let middle = try event(.otherMouseDown)
    XCTAssertEqual(middle.buttonNumber, 2)
    XCTAssertTrue(view.captures(middle, at: inside))
    XCTAssertEqual(WebLinkClick(event: middle)?.button, 1)
    XCTAssertEqual(WebLinkClick(event: try event(.rightMouseDown))?.button, 2)
  }

  func testMenuOrderAndActionsKeepOriginalLinkWhenViewChanges() async throws {
    let view = MessageLinkPointerTarget.TargetView()
    var actions: [(URL, MessageLinkAction)] = []
    view.actions = .init(activate: { _, _ in }, perform: { actions.append(($0, $1)) })
    let menu = try XCTUnwrap(view.menu(for: second))
    XCTAssertEqual(menu.items.map(\.title), ["在应用内浏览器打开", "在外部浏览器打开", "", "复制链接", "链接另存为…"])
    XCTAssertTrue(menu.items[2].isSeparatorItem)
    view.actions = .init(activate: { _, _ in }, perform: { _, _ in XCTFail("Menu must retain its originating action") })
    for item in menu.items where !item.isSeparatorItem {
      let target = try XCTUnwrap(item.target as? NSObject)
      _ = target.perform(try XCTUnwrap(item.action))
    }
    XCTAssertEqual(actions.count, 3, "Save As must wait for the context menu to close")
    try await Task.sleep(for: .milliseconds(25))
    XCTAssertEqual(actions.map(\.0), Array(repeating: second, count: 4))
    XCTAssertEqual(actions.map(\.1), MessageLinkAction.allCases)
  }

  func testModifiedClickUsesPressedLinkAndDraggingDoesNotActivate() throws {
    let view = MessageLinkPointerTarget.TargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    view.regions = [.init(url: first, rect: .init(x: 0, y: 0, width: 200, height: 80))]
    var clicked: [(URL, WebLinkClick)] = []
    view.actions = .init(activate: { clicked.append(($0, $1)) }, perform: { _, _ in })
    view.mouseDown(with: try event(.leftMouseDown, flags: .option))
    view.mouseUp(with: try event(.leftMouseUp, flags: .option))
    XCTAssertEqual(clicked.first?.0, first)
    XCTAssertEqual(clicked.first?.1.modifiers, .option)
    view.mouseDown(with: try event(.leftMouseDown, flags: .command))
    view.actions = .init(activate: { _, _ in XCTFail("Use the pressed link's original handler") }, perform: { _, _ in })
    view.mouseUp(with: try event(.leftMouseUp, flags: .command))
    XCTAssertEqual(clicked.count, 2)
    view.actions = .init(activate: { clicked.append(($0, $1)) }, perform: { _, _ in })
    view.mouseDown(with: try event(.leftMouseDown, flags: .command))
    view.mouseDragged(with: try event(.leftMouseDragged, point: .init(x: 45, y: 15), flags: .command))
    view.mouseUp(with: try event(.leftMouseUp, flags: .command))
    XCTAssertEqual(clicked.count, 2)
    view.mouseDown(with: try event(.leftMouseDown, flags: .command))
    view.regions = [.init(url: second, rect: .init(x: 0, y: 0, width: 200, height: 80))]
    view.mouseUp(with: try event(.leftMouseUp, flags: .command))
    XCTAssertEqual(clicked.count, 2, "Changing text between press and release must not open the old or new link")
  }

  func testExplicitCopyAndExternalOpenIgnoreOrdinaryClickPreference() throws {
    let store = WorkspaceStore()
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    store.performMessageLinkAction(.copy, url: second, ownerRunID: nil, pasteboard: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), second.absoluteString)
    var opened: [URL] = []
    store.library.webLinkTarget = .inAppBrowser
    store.performMessageLinkAction(.openExternal, url: first, ownerRunID: nil) { opened.append($0); return true }
    XCTAssertEqual(opened, [first])
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
  }

  func testRenderedLinksHaveSeparateWrappedRegionsAndSearchStillHighlights() async throws {
    guard #available(macOS 15, *) else { throw XCTSkip("TextRenderer requires macOS 15") }
    _ = NSApplication.shared
    let text = try AttributedString(markdown: "Plain [First](https://example.invalid/first) and [second long link that wraps onto several lines](https://example.invalid/second) tail")
    let id = ConversationTextID(run: "run", part: "response.0")
    let match = ConversationMatch(id: .init(text: id, location: 6, length: 5))
    let root = ConversationSearchText(text, id: id).font(.system(size: 16)).lineSpacing(5)
      .environment(\.conversationFind, .init(query: "First", active: match))
      .environment(\.messageLinkActions, .init(activate: { _, _ in }, perform: { _, _ in }))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: root)
    window.contentView = host
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for width in [240.0, 420.0] {
      window.setContentSize(.init(width: width, height: 180))
      var regions: [MessageLinkRegion] = []
      for _ in 0..<20 {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try await Task.sleep(for: .milliseconds(30))
        regions = descendants(host).compactMap { $0 as? MessageLinkPointerTarget.TargetView }.first?.regions ?? []
        if Set(regions.map(\.url)).count == 2 { break }
      }
      XCTAssertEqual(Set(regions.map(\.url)), [first, second])
      XCTAssertTrue(regions.allSatisfy { $0.rect.width > 0 && $0.rect.minX >= 0 && $0.rect.maxX <= width + 1 })
      if width == 240 { XCTAssertGreaterThan(regions.filter { $0.url == second }.count, 1) }
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: url.appendingPathComponent("message-links-\(Int(width)).png"))
      }
    }
  }
}
