import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class NoticeHostBoundsTests: XCTestCase {
  func testDestinationUsesMeasuredMainOrDetailInsteadOfWholeWindow() {
    let tracker = NoticeHostBoundsTracker()
    tracker.record(.root, frame: .init(x: 0, y: 0, width: 1100, height: 700))
    tracker.record(.detail, frame: .init(x: 245, y: 0, width: 855, height: 700))
    tracker.record(.workspace, frame: .init(x: 245, y: 0, width: 600, height: 700))
    var measured = tracker.bounds
    XCTAssertEqual(measured.rect(for: .workspace), .init(x: 245, y: 0, width: 600, height: 700))
    XCTAssertEqual(measured.rect(for: .settings), .init(x: 245, y: 0, width: 855, height: 700))
    XCTAssertEqual(measured.rect(for: .plugins), .init(x: 245, y: 0, width: 855, height: 700))
    XCTAssertEqual(measured.rect(for: .workspace)?.midX, 545)
    XCTAssertNotEqual(measured.rect(for: .workspace)?.midX, measured.root?.midX)
    measured.workspace = .init(x: 1000, y: 0, width: 500, height: 700)
    XCTAssertEqual(measured.rect(for: .workspace), .init(x: 1000, y: 0, width: 100, height: 700))
    measured.workspace = .init(x: 1500, y: 0, width: 200, height: 700)
    XCTAssertEqual(measured.rect(for: .workspace), measured.root)
  }

  func testHiddenNativeWorkspaceReportsMainAndDetailFrames() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let tracker = NoticeHostBoundsTracker()
    let host = NSHostingView(rootView: WorkspaceView(store: store)
      .coordinateSpace(name: NoticeHostBounds.coordinateSpace)
      .environment(\.noticeHostBoundsTracker, tracker))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(160)); host.layoutSubtreeIfNeeded()
    let rootFrame = try XCTUnwrap(tracker.bounds.root)
    let detail = try XCTUnwrap(tracker.bounds.detail)
    let workspace = try XCTUnwrap(tracker.bounds.workspace)
    XCTAssertGreaterThan(rootFrame.width, 1000)
    XCTAssertGreaterThan(detail.minX, rootFrame.minX)
    XCTAssertGreaterThan(detail.width, 600)
    XCTAssertGreaterThanOrEqual(workspace.minX, detail.minX)
    XCTAssertLessThanOrEqual(workspace.maxX, detail.maxX)
    XCTAssertEqual(tracker.bounds.rect(for: .workspace), workspace.intersection(rootFrame))
    XCTAssertFalse(window.isVisible)
  }
}
