import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class PopoutWindowLayoutTests: XCTestCase {
  @MainActor func testHomeAndThreadSurfacesRenderAtReferenceInitialSizes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let controller = PopoutWindowController(store: store)
    XCTAssertNil(controller.state.visibleSurface)
    XCTAssertFalse(controller.hasVisibleWindow, "Startup must not display the popout")
    let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
    XCTAssertEqual(panel.styleMask, .borderless)
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertTrue(panel.isMovableByWindowBackground)
    let task = try XCTUnwrap(store.createPopoutTask())

    let cases: [(String, NSSize, AnyView)] = [
      ("home", NSSize(width: 470, height: 290), AnyView(PopoutHomeView(store: store,
        onSubmit: { _, _ in false }, onHide: {}))),
      ("thread", NSSize(width: 470, height: 640), AnyView(PopoutThreadView(store: store,
        taskID: task.id, onHome: {}, onHide: {})))
    ]
    for (name, size, view) in cases {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: view)
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      try await Task.sleep(for: .milliseconds(180))
      host.layoutSubtreeIfNeeded()
      XCTAssertFalse(window.isVisible)
      XCTAssertGreaterThan(textViews(in: host).count, 0, name)
      let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 5_000, name)
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("popout-\(name).png"))
      }
      window.close()
    }
  }

  @MainActor private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
  }
}
