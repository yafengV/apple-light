import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FilePreviewFocusTests: XCTestCase {
  func testFocusRequestWaitsForFileLoadAndDoesNotAffectMainWorkspace() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.selectedFile = "File.swift"
    workspace.openFiles = ["File.swift"]
    workspace.fileLoading = true
    let mainFocus = store.workspace.fileFocusRequest
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    try await settle()
    let text = try XCTUnwrap(preview(host))
    // Set a distinct responder after initial mounting, then request focus while loading.
    window.makeFirstResponder(nil)
    workspace.fileFocusRequest = UUID()
    try await settle()
    XCTAssertFalse(window.firstResponder === text)
    workspace.fileText = "let loaded = true"
    workspace.fileLoading = false
    try await settle()
    XCTAssertTrue(window.firstResponder === text)
    XCTAssertEqual(text.string, "let loaded = true")
    XCTAssertEqual(store.workspace.fileFocusRequest, mainFocus)
    XCTAssertNil(store.workspace.selectedFile)
    window.acceptsFocus = false
    window.makeFirstResponder(nil)
    workspace.fileFocusRequest = UUID()
    try await settle()
    XCTAssertFalse(window.firstResponder === text, "An inactive window must not acquire file focus")
  }

  func testUnmountAndRemountRestoreSelectionAndScrollWithoutReplayingOldLineJump() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.selectedFile = "Long.swift"
    workspace.openFiles = ["Long.swift"]
    workspace.fileText = (1...200).map { "let row\($0) = \($0)" }.joined(separator: "\n")
    workspace.fileLineRange = NSRange(location: 0, length: 3)
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: AnyView(FileSourcePreview(store: store, workspace: workspace)))
    window.contentView = host
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    try await settle()
    let original = try XCTUnwrap(preview(host))
    let selected = NSRange(location: 300, length: 12)
    original.setSelectedRange(selected)
    let scroll = try XCTUnwrap(original.enclosingScrollView)
    original.layoutManager?.ensureLayout(for: original.textContainer!)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
    scroll.reflectScrolledClipView(scroll.contentView)
    let origin = scroll.contentView.bounds.origin
    XCTAssertGreaterThan(origin.y, 0)
    host.rootView = AnyView(EmptyView())
    try await settle()
    let saved = try XCTUnwrap(workspace.filePreviewPositions[root.path + "/Long.swift"])
    XCTAssertEqual(saved.selection, selected)
    XCTAssertEqual(saved.origin, origin)
    host.rootView = AnyView(FileSourcePreview(store: store, workspace: workspace))
    try await settle()
    let restored = try XCTUnwrap(preview(host))
    XCTAssertFalse(restored === original)
    XCTAssertEqual(restored.selectedRange(), selected)
    XCTAssertEqual(restored.enclosingScrollView?.contentView.bounds.origin.y ?? -1, origin.y, accuracy: 1)
    workspace.setProject(nil)
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
  }

  func testDismantleDuringLoadingDoesNotOverwriteSavedPosition() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp")
    workspace.openFiles = ["File.swift"]
    let key = "/tmp/File.swift"
    let saved = FilePreviewPosition(selection: NSRange(location: 42, length: 8), origin: NSPoint(x: 0, y: 120))
    workspace.filePreviewPositions[key] = saved
    let coordinator = FileSourcePreview.Coordinator()
    coordinator.workspace = workspace
    coordinator.identity = key
    coordinator.wasLoading = true
    let scroll = NSScrollView()
    scroll.documentView = NSTextView()
    FileSourcePreview.dismantleNSView(scroll, coordinator: coordinator)
    XCTAssertEqual(workspace.filePreviewPositions[key]?.selection, saved.selection)
    XCTAssertEqual(workspace.filePreviewPositions[key]?.origin, saved.origin)
  }

  func testClosingLastFileDropsItsPositionBeforePreviewUnmounts() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp")
    workspace.selectedFile = "File.swift"
    workspace.openFiles = ["File.swift"]
    workspace.filePreviewPositions["/tmp/File.swift"] = FilePreviewPosition(
      selection: NSRange(location: 42, length: 8), origin: NSPoint(x: 0, y: 120))
    workspace.closeFile("File.swift")
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
    let coordinator = FileSourcePreview.Coordinator()
    coordinator.workspace = workspace
    coordinator.identity = "/tmp/File.swift"
    let scroll = NSScrollView()
    scroll.documentView = NSTextView()
    FileSourcePreview.dismantleNSView(scroll, coordinator: coordinator)
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
  }
}

// XCTest is not the foreground GUI app. Control window eligibility while exercising
// the real hosting view, asynchronous load and AppKit responder chain.
private final class FilePreviewTestWindow: NSWindow {
  var acceptsFocus = true
  override var isKeyWindow: Bool { acceptsFocus }
}
