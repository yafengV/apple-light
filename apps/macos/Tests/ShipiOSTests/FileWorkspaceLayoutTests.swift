import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FileWorkspaceLayoutTests: XCTestCase {
  func testFileTreeCanHideWithoutLosingOpenEditor() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "let value = 42\n".write(to: root.appendingPathComponent("Edit.swift"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Edit.swift")
    await workspace.refreshFiles()

    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileWorkspaceView(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 850, height: 600)

    func editorX() async throws -> CGFloat {
      try await Task.sleep(for: .milliseconds(120))
      host.layoutSubtreeIfNeeded()
      func find(_ view: NSView) -> FilePreviewTextView? {
        if let editor = view as? FilePreviewTextView { return editor }
        return view.subviews.compactMap(find).first
      }
      let editor = try XCTUnwrap(find(host))
      XCTAssertEqual(editor.string, "let value = 42\n")
      return editor.convert(.zero, to: host).x
    }

    let withTree = try await editorX()
    XCTAssertGreaterThan(withTree, 180)
    workspace.fileTreeVisible = false
    let withoutTree = try await editorX()
    XCTAssertLessThan(withoutTree, 80)
    workspace.fileTreeVisible = true
    let restoredTree = try await editorX()
    XCTAssertGreaterThan(restoredTree, 180)
    window.setContentSize(.init(width: 500, height: 600))
    host.frame.size = .init(width: 500, height: 600)
    let compactEditor = try await editorX()
    XCTAssertLessThan(compactEditor, 80, "The editor should fill a narrow file panel")
    XCTAssertEqual(workspace.selectedFile, "Edit.swift")
  }
}
