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
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
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
  }
}
